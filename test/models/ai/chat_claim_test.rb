require "test_helper"

# Spike: two jobs on one chat turn. Part 1 runs today's code (Chat,
# AssistantResponseJob, Assistant::Builtin, Responder, a real write tool)
# with a fake provider, and two jobs at once on two threads, as on two
# Sidekiq threads or workers. Part 2 adds Sure's own claim
# (Ai::Spike::ChatClaim, after RubyLLM 2.2's "One Process at a Time").
class Ai::ChatClaimTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # The model asks for create_transaction (no external_id, so not
  # idempotent), then answers. A first round can wait on a gate (a proc), so
  # two jobs are in flight at once.
  class FakeLlm
    attr_reader :calls

    def initialize(account, first_round: nil)
      @account = account
      @first_round = first_round
      @calls = Concurrent::Array.new
    end

    def supports_responses_endpoint? = false

    def chat_response(_content, streamer:, function_results: [], messages: [], **)
      @calls << { round: function_results.empty? ? 1 : 2, thread: Thread.current.object_id, history: messages.size }
      if function_results.empty?
        @first_round&.call
        request = Provider::LlmConcept::ChatFunctionRequest.new(id: "fc1", call_id: "call_1", function_name: "create_transaction",
                                                                function_args: { account_id: @account.id, date: "2026-10-30", amount: 4.5, name: "Coffee" }.to_json)
        data = Provider::LlmConcept::ChatResponse.new(id: "r1", model: "gpt-4.1", messages: [], function_requests: [ request ])
      else
        streamer.call(Provider::LlmConcept::ChatStreamChunk.new(type: "output_text", data: "Added the coffee.", usage: nil))
        data = Provider::LlmConcept::ChatResponse.new(id: "r2", model: "gpt-4.1",
                                                      messages: [ Provider::LlmConcept::ChatMessage.new(id: "m", output_text: "Added the coffee.") ], function_requests: [])
      end
      streamer.call(Provider::LlmConcept::ChatStreamChunk.new(type: "response", data:, usage: nil))
      Provider::Response.new(success?: true, data:, error: nil)
    end
  end

  # Part 2's wiring, switched on per test: a turn claims its chat; a job that
  # finds it claimed drops a duplicate bubble or tries again later; the
  # responder renews the claim before each tool run and each event.
  module ClaimedChat
    singleton_class.attr_accessor :enabled, :skip_tool_renewal

    def ask_assistant(message, assistant_message: nil)
      return super unless ClaimedChat.enabled

      ran = Ai::Spike::ChatClaim.with_claim(self) { super; true }
      return if ran

      answered = messages.where(type: "AssistantMessage").where("created_at > ?", message.created_at).where.not(id: assistant_message&.id).exists?
      if answered
        assistant_message&.destroy                       # a duplicate (double Retry): the other job answers
      else
        AssistantResponseJob.set(wait: 5.seconds).perform_later(message, assistant_message) # a new message: after the turn
      end
      answered ? :duplicate : :requeued
    end

    # Assistant::Builtin rescues everything into the chat's error. A turn that
    # lost its claim has been replaced, so it stops quietly: in Sure this
    # would be one rescue clause in Builtin#respond_to.
    def add_error(error)
      return if ClaimedChat.enabled && error.is_a?(Ai::Spike::ChatClaim::Lost)

      super
    end
  end

  module RenewingResponder
    private def emit(...)
      Ai::Spike::ChatClaim.renew! if ClaimedChat.enabled
      super
    end
  end

  module RenewingToolCaller
    def fulfill_requests(...)
      Ai::Spike::ChatClaim.renew! if ClaimedChat.enabled && !ClaimedChat.skip_tool_renewal
      super
    end
  end

  TOOL_RUNS = Concurrent::Array.new

  module CountingTool
    def call(params = {}) = super.tap { TOOL_RUNS << _1 }
  end

  Chat.prepend(ClaimedChat)
  Assistant::Function::CreateTransaction.prepend(CountingTool)
  Assistant::Responder.prepend(RenewingResponder)
  Assistant::FunctionToolCaller.prepend(RenewingToolCaller)

  setup do
    @user = users(:family_admin)
    @account = accounts(:depository)
    @chat = Chat.create!(user: @user, title: "Claims")
    TOOL_RUNS.clear
    # Load what the jobs' threads use here, on one thread: tests autoload,
    # and production eager-loads.
    [ Ai::Spike::ChatClaim, Ai::Spike::LaneSlot, AssistantResponseJob, Assistant::Builtin, Assistant::Responder ].each(&:name)
    # Each test enqueues the turns it wants; the message's own callback would
    # add another pending bubble and job.
    UserMessage.any_instance.stubs(:request_response_later)
  end

  teardown do
    ClaimedChat.enabled = false
    ClaimedChat.skip_tool_renewal = false
    # The columns rolled back with the test's transaction.
    ActiveRecord::Base.connection.schema_cache.clear_data_source_cache!("chats")
    Chat.reset_column_information
    Ai::Spike::ChatClaim.ttl = 10.minutes
  end

  def add_columns
    ActiveRecord::Migration.suppress_messages do
      ActiveRecord::Migration.add_column :chats, :claim_token, :string
      ActiveRecord::Migration.add_column :chats, :claimed_until, :datetime
    end
    Chat.reset_column_information
    ClaimedChat.enabled = true
  end

  def use(llm) = Assistant::Builtin.any_instance.stubs(:get_model_provider).returns(llm)

  # A user message whose own job is discarded, so each test enqueues what it
  # wants.
  def ask(content = "I bought a coffee for 4.50")
    message = @chat.messages.create!(type: "UserMessage", content:, ai_model: "gpt-4.1")
    clear_enqueued_jobs
    message
  end

  # Two Retry requests at the same moment: both read the user's message as
  # the chat's last before either adds its bubble, which is all
  # retry_last_message! checks. One after the other, the second does nothing.
  def retry_twice_at_once(message)
    2.times { @chat.ask_assistant_later(message) }
  end

  def run_concurrently(jobs) = jobs.map { |job| Thread.new { ActiveJob::Base.execute(job) } }.each(&:join)

  def take_enqueued
    jobs = enqueued_jobs.map { |job| job[:job].new(*ActiveJob::Arguments.deserialize(job[:args])).serialize }
    clear_enqueued_jobs
    jobs
  end

  def two_at_once
    arrived = Concurrent::AtomicFixnum.new
    lambda do
      arrived.increment
      deadline = Time.current + 1.5
      sleep 0.01 until arrived.value >= 2 || Time.current > deadline
    end
  end

  def outcome
    assistants = @chat.messages.where(type: "AssistantMessage").order(:created_at)
    {
      answers: assistants.map { [ _1.status, _1.content.truncate(30) ] },
      tool_runs: TOOL_RUNS.map { _1.is_a?(Hash) ? (_1[:success] || _1["success"]) : _1 },
      coffees: @account.entries.where(name: "Coffee").count,
      error: @chat.reload.error.present?
    }
  end

  def say(label, value) = (puts "\n  #{label}: #{value.inspect}" if ENV["SPIKE_PRINT"])

  # Part 1: today

  test "today: Retry pressed again after the first does nothing" do
    message = ask
    2.times { @chat.retry_last_message! }
    assert_equal 1, take_enqueued.size
    assert message.persisted?
  end

  test "today: two Retry requests at once run two turns, and the write tool twice" do
    use FakeLlm.new(@account, first_round: two_at_once)
    message = ask
    retry_twice_at_once(message)
    jobs = take_enqueued
    assert_equal 2, jobs.size

    run_concurrently(jobs)
    result = outcome
    say "double Retry, today", result
    assert_equal 2, result[:coffees], "two coffees from one message"
    assert message.persisted?
  end

  test "today: a second message while a turn runs starts a second turn at once" do
    gate = Concurrent::Event.new
    llm = FakeLlm.new(@account, first_round: -> { gate.wait(1.5) unless Thread.current[:second] })
    use llm
    @chat.ask_assistant_later(ask)
    first = take_enqueued
    @chat.ask_assistant_later(ask("And a muffin"))
    second = take_enqueued
    threads = [ Thread.new { ActiveJob::Base.execute(first.first) },
                Thread.new { Thread.current[:second] = true; ActiveJob::Base.execute(second.first) } ]
    sleep 0.3
    gate.set
    threads.each(&:join)

    result = outcome.merge(rounds: llm.calls.map { _1.slice(:round, :history) })
    say "second message mid-turn, today", result
    assert_equal 2, llm.calls.count { _1[:round] == 1 }, "both turns called the model"
  end

  # Part 2: Sure's own claim

  test "claim: two Retry requests at once run one turn; the other job drops its bubble" do
    add_columns
    use FakeLlm.new(@account, first_round: two_at_once)
    message = ask
    retry_twice_at_once(message)
    run_concurrently(take_enqueued)

    result = outcome
    say "double Retry, claimed", result
    assert_equal 1, result[:coffees]
    assert_equal 1, result[:answers].size
    assert_not Ai::Spike::ChatClaim.running?(@chat), "released"
  end

  test "claim: a second message while a turn runs waits for it" do
    add_columns
    gate = Concurrent::Event.new
    llm = FakeLlm.new(@account, first_round: -> { gate.wait(1.5) unless Thread.current[:second] })
    use llm
    @chat.ask_assistant_later(ask)
    first = take_enqueued
    @chat.ask_assistant_later(ask("And a muffin"))
    second = take_enqueued
    threads = [ Thread.new { ActiveJob::Base.execute(first.first) },
                Thread.new do
                  sleep 0.01 until Ai::Spike::ChatClaim.running?(@chat) # the first turn has claimed the chat
                  Thread.current[:second] = true
                  ActiveJob::Base.execute(second.first)
                  gate.set
                end ]
    threads.each(&:join)

    requeued = enqueued_jobs.select { _1[:job] == AssistantResponseJob }.map { [ _1[:job].name, _1[:at].present? ] }
    say "second message mid-turn, claimed", outcome.merge(requeued:)
    assert_equal [ [ "AssistantResponseJob", true ] ], requeued
  end

  test "claim: a turn whose claim lapsed stops; the turn that took over answers once" do
    add_columns
    Ai::Spike::ChatClaim.ttl = 1.second
    stuck = Concurrent::Event.new
    use FakeLlm.new(@account, first_round: -> { stuck.wait(5) if Thread.current[:stale] })
    message = ask
    retry_twice_at_once(message)
    stale_job, fresh_job = take_enqueued

    stale = Thread.new { Thread.current[:stale] = true; ActiveJob::Base.execute(stale_job) }
    sleep 1.3                                  # the stale turn's claim lapses while its model call hangs
    assert_not Ai::Spike::ChatClaim.running?(@chat)
    Thread.new { ActiveJob::Base.execute(fresh_job) }.join
    stuck.set
    stale.join

    result = outcome
    say "lapsed claim", result
    assert_equal 1, result[:coffees], "the stale turn stopped before its tool ran"
    assert_not result[:error], "and said nothing"
  end

  test "claim: without renewing before the tool runs, a lapsed turn writes again" do
    add_columns
    ClaimedChat.skip_tool_renewal = true
    Ai::Spike::ChatClaim.ttl = 1.second
    stuck = Concurrent::Event.new
    use FakeLlm.new(@account, first_round: -> { stuck.wait(5) if Thread.current[:stale] })
    message = ask
    retry_twice_at_once(message)
    stale_job, fresh_job = take_enqueued

    stale = Thread.new { Thread.current[:stale] = true; ActiveJob::Base.execute(stale_job) }
    sleep 1.3
    Thread.new { ActiveJob::Base.execute(fresh_job) }.join
    stuck.set
    stale.join

    result = outcome
    say "lapsed claim, no renewal before tools", result
    assert_equal 2, result[:coffees], "the claim alone doesn't stop the stale turn's write"
  end

  test "claim: a chat waiting at the gate longer than the claim lets a second turn in" do
    add_columns
    Ai::Spike::ChatClaim.ttl = 1.second
    slot = Ai::Spike::LaneSlot.new(1)
    held = Concurrent::Event.new
    second_done = Concurrent::Event.new
    # Background work holds the host's gate until the second turn is done, so
    # the waiting turn's claim lapses while it waits, whatever the CPU's speed.
    background = Thread.new { slot.hold(:background) { held.set; second_done.wait(10) } }
    held.wait(1)
    use FakeLlm.new(@account, first_round: -> { slot.hold(:interactive) { nil } unless Thread.current[:second] })
    message = ask
    retry_twice_at_once(message)
    waiting_job, second_job = take_enqueued

    waiting = Thread.new { ActiveJob::Base.execute(waiting_job) }
    sleep 0.01 until Ai::Spike::ChatClaim.running?(@chat)  # the waiting turn has claimed the chat
    sleep 0.01 while Ai::Spike::ChatClaim.running?(@chat)  # and its claim has lapsed at the gate
    second = Thread.new do
      Thread.current[:second] = true
      ActiveJob::Base.execute(second_job)
    ensure
      second_done.set
    end
    [ waiting, second, background ].each(&:join)

    result = outcome
    say "waiting at the gate past the claim", result
    # The second turn took the lapsed claim and answered; the waiting turn's
    # model call was wasted, and its renewal before the tool run stopped it.
    assert_equal 1, result[:coffees]
    assert_equal 1, result[:answers].size
  end
end
