require_relative "spike_helper"
require_relative "ruby_llm_persistence_live_test"

# Spike: RubyLLM's usage ledger (ruby_llm_usages, RubyLLM::Accounting::Usage)
# against Sure's llm_usages. Three ways to record usage:
#   A. the ledger itself: RubyLLM writes a row per provider attempt, owned by
#      whatever Usage.with_owner set (here, the family);
#   B. RubyLLM's usage.ruby_llm event, which fires per attempt with or
#      without the table, written into llm_usages by a Sure subscriber;
#   C. Sure's own .ai events (the plan, section 10): one per wire call.
# WebMock with the OpenAI-compatible shapes; no server. The ledger's tables
# come from RubyLLM's install template, created inside each test's
# transaction, so the DDL rolls back.
class Ai::RubyLlmUsageLedgerTest < ActiveSupport::TestCase
  include AiSpikeHelper

  URL = "http://ledger.test/v1".freeze
  CHAT_URL = "#{URL}/chat/completions".freeze

  setup do
    @family = families(:dylan_family)
    @endpoint = Ai::Spike::Endpoint.new(name: "ledger", protocol: :compatible, preset: :llama_cpp, base_url: URL, api_key: "k", json_mode: "strict")
    @route = Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint: @endpoint, name: "local-model", max_output_tokens: 1024))
    forget_ledger_table
  end

  teardown do
    ActiveSupport::Notifications.unsubscribe(@usage_subscriber) if @usage_subscriber
  end

  def completion(content = AiSpikeHelper::NETFLIX_JSON, prompt: 400, cached: nil)
    usage = { prompt_tokens: prompt, completion_tokens: 100, total_tokens: prompt + 100 }
    usage[:prompt_tokens_details] = { cached_tokens: cached } if cached
    { status: 200, headers: { "Content-Type" => "application/json" }, body: {
      id: "c1", object: "chat.completion", model: "local-model",
      choices: [ { index: 0, finish_reason: "stop", message: { role: "assistant", content: } } ], usage:
    }.to_json }
  end

  def sse(content)
    chunks = content.chars.each_slice(20).map { { id: "c1", object: "chat.completion.chunk", model: "local-model", choices: [ { index: 0, delta: { content: _1.join } } ] } }
    chunks << { id: "c1", object: "chat.completion.chunk", model: "local-model", choices: [], usage: { prompt_tokens: 400, completion_tokens: 100, total_tokens: 500 } }
    { status: 200, headers: { "Content-Type" => "text/event-stream" }, body: chunks.map { "data: #{_1.to_json}\n\n" }.join + "data: [DONE]\n\n" }
  end

  def error(status, message) = { status:, headers: { "Content-Type" => "application/json" }, body: { error: { message:, type: "server_error" } }.to_json }

  def ledger_rows = RubyLLM::ActiveRecord::Usage.chronological.map { _1.attributes.symbolize_keys.slice(:operation, :status, :input_tokens, :output_tokens, :total_cost).merge(owner: _1.owner_type) }

  def create_ledger
    persistence = Ai::RubyLlmPersistenceLiveTest
    ActiveRecord::Migration.suppress_messages do
      source = persistence::Template.new(persistence::TEMPLATES.join("create_ruby_llm_records_migration.rb.tt")).render
      klass = source[/class (\w+)/, 1]
      self.class.const_get(klass) rescue self.class.class_eval(source) # rubocop:disable Style/RescueModifier
      self.class.const_get(klass).new.migrate(:up)
    end
    forget_ledger_table
  end

  # The schema cache remembers whether the table exists for the rest of the
  # process, and the DDL of an earlier test rolled back.
  def forget_ledger_table
    ActiveRecord::Base.connection.schema_cache.clear_data_source_cache!("ruby_llm_usages")
    RubyLLM::ActiveRecord::Usage.reset_column_information
  end

  def capture_usage_events
    events = Concurrent::Array.new
    @usage_subscriber = ActiveSupport::Notifications.subscribe("usage.ruby_llm") do |*, payload|
      events << payload.slice(:operation, :status, :owner).merge(input: payload[:tokens]&.input, cost: payload[:cost]&.total,
                                                                 correlation_id: Ai::Correlation.current, thread: Thread.current.object_id)
    end
    events
  end

  def sql_statements
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql].squish.truncate(70) }
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def say(label, value) = (puts "\n  #{label}: #{value.inspect}" if ENV["SPIKE_PRINT"])

  test "A: one call, owned by the family; Sure's feature name has nowhere to go" do
    create_ledger
    stub_request(:post, CHAT_URL).to_return(completion)

    RubyLLM::Accounting::Usage.with_owner(@family) { bill_setup.call(route: @route) }

    rows = ledger_rows
    say "rows", rows
    assert_equal [ { operation: "chat", status: "succeeded", input_tokens: 400, output_tokens: 100, total_cost: nil, owner: "Family" } ], rows
    row = RubyLLM::ActiveRecord::Usage.last
    assert_equal @family, row.owner
    assert_equal [ "openai", "local-model" ], [ row.provider, row.model ], "provider is RubyLLM's slug, not Sure's endpoint"
    assert_not_includes RubyLLM::ActiveRecord::Usage.column_names, "metadata"
    assert_raises(ArgumentError) { RubyLLM::Accounting::Usage::Entry.new(operation: :suggest_bill_setup, provider: "openai", model: "m") }
  end

  test "A: a call outside with_owner leaves an ownerless row" do
    create_ledger
    stub_request(:post, CHAT_URL).to_return(completion)
    bill_setup.call(route: @route)
    assert_equal [ nil ], RubyLLM::ActiveRecord::Usage.pluck(:owner_type)
  end

  test "A, B, C: retries, a refusal and the auto JSON-mode chain" do
    create_ledger
    events = capture_usage_events
    retrying = Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint: @endpoint.with(max_retries: 2, json_mode: "auto"), name: "local-model", max_output_tokens: 1024))
    # Two 503s RubyLLM retries, then a 400 on strict that the auto chain
    # answers with json_object, which succeeds.
    stub_request(:post, CHAT_URL).to_return(error(503, "busy"), error(503, "busy"), error(400, "response_format json_schema is not supported"), completion)

    ai_events = capture_ai_events do
      Ai::Correlation.with("corr-1") { RubyLLM::Accounting::Usage.with_owner(@family) { bill_setup.call(route: retrying) } }
    end

    rows = ledger_rows
    say "ledger rows", rows
    say "usage.ruby_llm events", events.map { _1.except(:thread) }
    say ".ai events", ai_events.map { { name: _1.name, usage: _1.payload[:usage]&.to_h, error: _1.payload[:error] } }
    assert_equal 4, WebMock::RequestRegistry.instance.times_executed(WebMock::RequestPattern.new(:post, CHAT_URL))
    assert_equal rows.size, events.size, "an event for every row"
    assert_equal [ "corr-1" ], events.map { _1[:correlation_id] }.uniq, "the subscriber runs in the caller, so it sees Sure's context"
    assert_equal 1, ai_events.size
  end

  test "A, B: a call the gate interrupts, then resent" do
    create_ledger
    events = capture_usage_events
    stub_request(:post, CHAT_URL).to_return(sse(AiSpikeHelper::NETFLIX_JSON), sse(AiSpikeHelper::NETFLIX_JSON))

    RubyLLM::Accounting::Usage.with_owner(@family) do
      Ai::Spike::LaneSlot.with_interrupt do
        Ai::Spike::LaneSlot.interrupt.make_true
        assert_raises(Ai::Spike::LaneSlot::Preempted) { bill_setup.call(route: @route) }
        Ai::Spike::LaneSlot.interrupt.make_false
        assert_netflix bill_setup.call(route: @route).value
      end
    end

    rows = ledger_rows
    say "ledger rows", rows
    say "events", events.map { _1.slice(:status, :input) }
    assert_equal %w[failed succeeded], rows.map { _1[:status] }, "Preempted isn't CancelledError, so it's a failure"
  end

  test "A: embeddings, and cached prompt tokens" do
    create_ledger
    stub_request(:post, "#{URL}/embeddings").to_return(status: 200, headers: { "Content-Type" => "application/json" },
      body: { object: "list", model: "embed", data: [ { object: "embedding", index: 0, embedding: [ 0.1, 0.2 ] } ], usage: { prompt_tokens: 7, total_tokens: 7 } }.to_json)
    stub_request(:post, CHAT_URL).to_return(completion(prompt: 12_457, cached: 11_945))

    sure_usage = nil
    RubyLLM::Accounting::Usage.with_owner(@family) do
      Ai::Transport.for(@endpoint).embed([ "groceries" ], model: Ai::Spike::Model.new(endpoint: @endpoint, name: "embed", embedding_dimensions: 2))
      sure_usage = bill_setup.call(route: @route).usage
    end

    rows = RubyLLM::ActiveRecord::Usage.chronological.map { _1.attributes.symbolize_keys.slice(:operation, :input_tokens, :cache_read_tokens) }
    say "rows", rows
    say "Sure's usage", sure_usage.to_h
    assert_equal "embedding", rows.first[:operation]
    assert_equal sure_usage.input_tokens, rows.last[:input_tokens], "both read RubyLLM's tokens: cached tokens left out the same way"
  end

  test "A: prices come only from RubyLLM's registry" do
    create_ledger
    gemini = Ai::Spike::Endpoint.new(name: "gemini", protocol: :compatible, preset: :gemini_native, base_url: "https://generativelanguage.googleapis.com", api_key: "k", json_mode: "strict")
    stub_request(:post, CHAT_URL).to_return(completion)
    stub_request(:post, %r{generativelanguage.googleapis.com/.*generateContent}).to_return(status: 200, headers: { "Content-Type" => "application/json" },
      body: { candidates: [ { content: { role: "model", parts: [ { text: AiSpikeHelper::NETFLIX_JSON } ] }, finishReason: "STOP" } ],
              usageMetadata: { promptTokenCount: 400, candidatesTokenCount: 100, totalTokenCount: 500 }, modelVersion: "gemini-3.5-flash-lite" }.to_json)

    RubyLLM::Accounting::Usage.with_owner(@family) do
      bill_setup.call(route: @route)
      bill_setup.call(route: Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint: gemini, name: "gemini-3.5-flash-lite", max_output_tokens: 1024)))
    end

    costs = RubyLLM::ActiveRecord::Usage.chronological.pluck(:model, :total_cost)
    say "costs", costs
    assert_nil costs.first.last, "a local model has no price"
  end

  [ false, true ].each do |table|
    test "A: SQL per call, #{table ? "with" : "without"} the table" do
      stub_request(:post, CHAT_URL).to_return(completion)
      table ? create_ledger : forget_ledger_table
      bill_setup.call(route: @route)
      statements = sql_statements { bill_setup.call(route: @route) }
      say "SQL per call, table #{table}", statements
      assert_equal table ? 1 : 0, statements.count { _1.start_with?("INSERT") }
    end
  end

  # The owner lives in fiber storage, which new threads inherit; Sure's lane
  # lives in ActiveSupport::IsolatedExecutionState, which RubyLLM's tool
  # threads start without.
  class ProbeTool < RubyLLM::Tool
    PROBES = Concurrent::Array.new
    parameter :text, description: "Any text"

    def execute(text:)
      PROBES << { tool: name, owner: RubyLLM::Accounting::Usage.owner&.class&.name, fiber_lane: Fiber[:spike_lane],
                  isolated_lane: ActiveSupport::IsolatedExecutionState[:spike_lane], thread: Thread.current.object_id }
      "ok"
    end
  end

  class ProbeA < ProbeTool
    description "Probe A"
    def name = "probe_a"
  end

  class ProbeB < ProbeTool
    description "Probe B"
    def name = "probe_b"
  end

  test "A: the usage owner, and a lane in fiber storage, follow RubyLLM's tool threads" do
    ProbeTool::PROBES.clear
    calls = %w[probe_a probe_b].each_with_index.map { |name, i| { id: "call_#{i}", type: "function", function: { name:, arguments: { text: "x" }.to_json } } }
    stub_request(:post, CHAT_URL).to_return(
      { status: 200, headers: { "Content-Type" => "application/json" }, body: {
        id: "c1", object: "chat.completion", model: "local-model",
        choices: [ { index: 0, finish_reason: "tool_calls", message: { role: "assistant", content: nil, tool_calls: calls } } ],
        usage: { prompt_tokens: 50, completion_tokens: 10, total_tokens: 60 } }.to_json },
      completion("done")
    )
    context = Ai::Transport.for(@endpoint).send(:ruby_llm_context)
    chat = context.chat(model: "local-model", provider: :openai, protocol: :chat_completions, assume_model_exists: true)
                  .with_tools(ProbeA.new, ProbeB.new).with_tool_options(concurrency: :threads)
    chat.add_message(role: :user, content: "Call both probes.")

    caller_thread = Thread.current.object_id
    RubyLLM::Accounting::Usage.with_owner(@family) do
      Fiber[:spike_lane] = :interactive
      ActiveSupport::IsolatedExecutionState[:spike_lane] = :interactive
      chat.step
      chat.run_tools
    ensure
      Fiber[:spike_lane] = nil
      ActiveSupport::IsolatedExecutionState[:spike_lane] = nil
    end

    probes = ProbeTool::PROBES.to_a
    say "probes", probes.map { _1.merge(other_thread: _1[:thread] != caller_thread).except(:thread) }
    assert_equal 2, probes.size
    assert probes.all? { _1[:thread] != caller_thread }, "the tools ran on their own threads"
  end
end
