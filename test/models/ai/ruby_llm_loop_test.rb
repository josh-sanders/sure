require_relative "spike_helper"

# Spike: RubyLLM runs Sure's tools (Chat#run_tools) while Ai::Conversation
# still steps the loop and keeps its bounds. Live on llama.cpp, with one
# OpenRouter run for the reasoning_details round trip.
class Ai::RubyLlmLoopTest < ActiveSupport::TestCase
  include AiSpikeHelper

  INSTRUCTIONS = "You are a finance assistant. Use tools to look up or change the user's data. Be brief.".freeze

  setup do
    @user = users(:family_admin)
    @tool_events = []
    @tool_subscriber = ActiveSupport::Notifications.subscribe("tool_call.ruby_llm") do |event|
      @tool_events << [ event.payload[:tool_name], Thread.current ]
    end
  end

  teardown { ActiveSupport::Notifications.unsubscribe(@tool_subscriber) }

  def functions(*names) = names.map { "Assistant::Function::#{_1.to_s.camelize}".constantize.new(@user) }

  def conversation(route = llama_route, functions: functions(:get_accounts), max_tool_rounds: 4, turn_timeout: 600, **)
    Ai::Conversation::RubyLlmLoop.new(route:, functions:, max_tool_rounds:, turn_timeout:, instructions: INSTRUCTIONS, **)
  end

  def ask(text) = [ Ai::Transport::Base::Message.new(role: :user, content: text) ]

  def roles(body) = body["messages"].map { _1["role"] }

  def llama_bodies = request_bodies(%r{llama-cpp.test|8180})

  def ski_trip? = @user.family.tags.where("lower(name) = ?", "ski trip").exists?

  test "RubyLLM runs Sure's tool between two rounds Sure drives (live)" do
    chunks = []
    events = capture_ai_events do
      with_spike_cassette("llama_cpp/loop_tool_round") do
        @result = conversation.respond(ask("How many accounts do I have? Look them up.")) { chunks << _1 }
      end
    end

    assert_equal [ 2, :complete ], [ @result.rounds, @result.status ]
    user, assistant, tool, answer = @result.messages
    assert_equal [ :user, :assistant, :tool, :assistant ], @result.messages.map(&:role)
    assert_equal [ "get_accounts" ], assistant.tool_calls.map(&:name)
    assert_equal assistant.tool_calls.first.id, tool.tool_call_id
    assert JSON.parse(tool.content)["accounts"].any?, "Sure's function result, as JSON"
    assert_equal answer.content, @result.text
    assert_operator chunks.size, :>, 1, "the answer streams"
    assert_equal "How many accounts do I have? Look them up.", user.content

    assert_equal %w[converse.ai converse.ai], events.map(&:name), "one Sure event per round, as before"
    assert_equal [ 1, 2 ], events.map { _1.payload[:prompt][:metadata][:round] }
    assert_equal [ %i[user], %i[user assistant tool] ], events.map { |e| e.payload[:prompt][:messages].map(&:role) }
    assert_equal [ [ "get_accounts", Thread.current ] ], @tool_events, "and RubyLLM's own tool_call.ruby_llm, in the job's thread"
    assert_equal [ %w[system user], %w[system user assistant tool] ], llama_bodies.map { roles(_1) }
  end

  test "the last round sends tool_choice none, so the model must answer (live)" do
    with_spike_cassette("llama_cpp/loop_final_round") do
      @result = conversation(max_tool_rounds: 1).respond(ask("How many accounts do I have? Look them up."))
    end

    assert_equal [ 1, :complete ], [ @result.rounds, @result.status ]
    assert_empty @result.messages.last.tool_calls
    assert_equal "none", llama_bodies.sole["tool_choice"]
    assert_empty @tool_events
  end

  test "with concurrency: :threads, one round's tool calls run in their own threads (live)" do
    with_spike_cassette("llama_cpp/loop_parallel_tools") do
      @result = conversation(functions: functions(:get_accounts, :get_categories), concurrency: :threads)
                  .respond(ask("How many accounts and how many categories do I have? Call both tools at once."))
    end

    assistant = @result.messages[1]
    assert_equal %w[get_accounts get_categories], assistant.tool_calls.map(&:name).sort, "both calls in one round"
    assert_equal %w[get_accounts get_categories], @tool_events.map(&:first).sort
    assert @tool_events.none? { _2 == Thread.current }, "each tool ran off the job's thread"
    assert_equal 2, @result.rounds
    tool_results = @result.messages.select { _1.role == :tool }
    assert_equal assistant.tool_calls.map(&:id).sort, tool_results.map(&:tool_call_id).sort
    assert JSON.parse(tool_results.find { _1.tool_call_id == assistant.tool_calls.find { |c| c.name == "get_categories" }.id }.content).present?
  end

  test "a write tool waits for approval: the turn ends, then resumes once approved (live)" do
    decisions = {}
    convo = -> { conversation(functions: functions(:get_tags, :create_tag), approval: ->(call) { decisions[call.id] }) }

    with_spike_cassette("llama_cpp/loop_approval_approved") do
      @paused = convo.().respond(ask("Create a tag called Ski trip."))

      assert_equal :awaiting_approval, @paused.status
      assert_equal [ "create_tag" ], @paused.pending.map(&:name)
      assert_equal [ :user, :assistant ], @paused.messages.map(&:role), "the history Sure stores while it waits"
      assert_not ski_trip?

      decisions[@paused.pending.sole.id] = true
      @result = convo.().respond(@paused.messages)   # a later job, from the stored history
    end

    assert_equal :complete, @result.status
    assert ski_trip?
    assert_equal [ :user, :assistant, :tool, :assistant ], @result.messages.map(&:role)
    assert_equal true, JSON.parse(@result.messages[2].content)["success"]
    assert_equal [ %w[system user], %w[system user assistant tool] ], llama_bodies.map { roles(_1) }
  end

  test "a denied write tool sends the model RubyLLM's denial instead (live)" do
    decisions = {}
    convo = -> { conversation(functions: functions(:get_tags, :create_tag), approval: ->(call) { decisions[call.id] }) }

    with_spike_cassette("llama_cpp/loop_approval_denied") do
      paused = convo.().respond(ask("Create a tag called Ski trip."))
      decisions[paused.pending.sole.id] = false
      @result = convo.().respond(paused.messages)
    end

    assert_equal :complete, @result.status
    assert_not ski_trip?
    assert_empty @tool_events, "create_tag never ran"
    denial = @result.messages[2]
    assert_equal :tool, denial.role
    @denial = denial.content
    assert_match(/denied|not approved|declined/i, denial.content)
    assert @result.text.present?
  end

  test "a history whose last tool call has no result runs it first: a worker that died mid-round (live)" do
    call = Ai::Transport::Base::ToolCall.new(id: "call_dead_worker", name: "get_accounts", arguments: {})
    history = ask("How many accounts do I have? Look them up.") +
              [ Ai::Transport::Base::Message.new(role: :assistant, content: "", tool_calls: [ call ]) ]

    with_spike_cassette("llama_cpp/loop_resume_dead_worker") do
      @result = conversation.respond(history)
    end

    assert_equal [ [ "get_accounts", Thread.current ] ], @tool_events
    assert_equal [ :user, :assistant, :tool, :assistant ], @result.messages.map(&:role)
    assert_equal "call_dead_worker", @result.messages[2].tool_call_id
    assert_equal %w[system user assistant tool], roles(llama_bodies.sole)
  end

  # Both replay round one of loop_tool_round, which asks for get_accounts.
  test "a cancel after round one stops the turn before the tool runs" do
    cancel = false
    after_round = ActiveSupport::Notifications.subscribe("converse.ai") { cancel = true }
    with_spike_cassette("llama_cpp/loop_tool_round") do
      assert_raises(Ai::Error::Cancelled) { conversation(cancelled: -> { cancel }).respond(ask("How many accounts do I have? Look them up.")) }
    end

    assert_empty @tool_events
  ensure
    ActiveSupport::Notifications.unsubscribe(after_round)
  end

  test "the turn deadline is checked before each tool, too" do
    late = false
    after_round = ActiveSupport::Notifications.subscribe("converse.ai") { late = true }
    convo = conversation(turn_timeout: 10)
    convo.define_singleton_method(:now) { late ? 100 : 0 }
    with_spike_cassette("llama_cpp/loop_tool_round") do
      assert_raises(Ai::Error::Timeout) { convo.respond(ask("How many accounts do I have? Look them up.")) }
    end

    assert_empty @tool_events
  ensure
    ActiveSupport::Notifications.unsubscribe(after_round)
  end

  test "a tool's failure still comes back as Sure's data, not SQL or an exception" do
    function = Assistant::Function::GetAccounts.new(@user)
    function.stubs(:call).raises(ActiveRecord::RecordNotFound, "Couldn't find Account with SELECT accounts.* FROM accounts INNER JOIN account_shares ...")

    result = Ai::Conversation::SureTool.for(function).call

    assert_equal "No such record, or it is not one you have access to", result["error"]
    assert_no_match(/SELECT/, result.to_json)
  end

  test "only write tools wait for approval" do
    approval = ->(_) { nil }
    assert_not Ai::Conversation::SureTool.for(Assistant::Function::GetTags.new(@user), approval:).requires_approval?
    assert Ai::Conversation::SureTool.for(Assistant::Function::CreateTag.new(@user), approval:).requires_approval?
    assert_not Ai::Conversation::SureTool.for(Assistant::Function::CreateTag.new(@user)).requires_approval?
    writes = Assistant.function_classes(@user).map(&:name).grep_v(Ai::Conversation::SureTool::READ_ONLY)
    assert_operator writes.size, :>, 15
  end

  test "OpenRouter: RubyLLM keeps reasoning_details between the rounds itself (live)" do
    endpoint = Ai::Spike::Presets.openrouter(api_key: ENV.fetch("SPIKE_OPENROUTER_API_KEY", "or-key"), max_retries: 0)
    route = Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint:, name: "nvidia/nemotron-3.5-lightning:free", max_output_tokens: 4096))
    with_spike_cassette("openrouter/loop_tool_round") do
      @result = conversation(route, turn_timeout: 300).respond(ask("How many accounts do I have? Look them up."))
    end

    assert_equal [ 2, :complete ], [ @result.rounds, @result.status ]
    assert_equal [ "get_accounts" ], @tool_events.map(&:first)
    second = request_bodies(%r{openrouter\.ai}).last
    assert_equal %w[system user assistant tool], roles(second)
    assert second["messages"].find { _1["role"] == "assistant" }["reasoning_details"].present?
    assert @result.messages[1].provider_state[:raw_reasoning].present?, "and hands it back for Sure to store"
  end

  test "Sure's whole tool list, in input tokens, on llama.cpp (live)" do
    tools = Assistant.function_classes(@user).map { _1.new(@user) }
                     .map { Ai::Transport::Base::ToolSpec.new(name: _1.name, description: _1.description, schema: _1.params_schema) }
    route = Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint: Ai::Spike::Presets.llama_cpp, name: LLAMA_MODEL, max_output_tokens: 1))
    transport = Ai::Transport.for(route.endpoint)
    request = ->(with) do
      Ai::Transport::Base::ConverseRequest.new(model: route.model, instructions: INSTRUCTIONS, messages: ask("Hi"),
                                               tools: with, tool_choice: with.any? ? :none : nil, max_tokens: 1)
    end
    # RubyLLM's input_tokens leaves out cached tokens, and llama.cpp had most
    # of the tool list cached from an earlier run: count both.
    prompt = ->(usage) { usage.input_tokens + usage.cache_read_tokens }
    with_spike_cassette("llama_cpp/loop_tool_list_tokens") do
      @without = prompt.(transport.converse(request.([])).usage)
      @with = prompt.(transport.converse(request.(tools)).usage)
    end

    assert_equal 34, tools.size, "without preview features"
    assert_equal tools.size, request_bodies(%r{llama-cpp.test|8180}).last["tools"].size
    assert_equal [ 39, 12_457 ], [ @without, @with ], "the tool list adds 12,418 prompt tokens to every round"
  end
end
