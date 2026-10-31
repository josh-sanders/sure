require_relative "async_spike_helper"
require_relative "../ruby_llm_persistence_live_test"

# Spike: RubyLLM agents (RubyLLM::Agent, rubyllm.com/agents) behind the gate
# of §11. The agent is built on Sure's RubyLLM context for the endpoint
# (the agent's `context`), so every request it makes passes the instrumenter
# and the host's gate (Ai::Spike::LaneSlot, one slot, preempt on). Sure keeps
# the loop bounds by stepping the agent (Agent#step) rather than calling ask.
#
# - agent_interrupted: a background agent with a tool, on llama.cpp; a chat
#   arrives while the agent writes its final answer and interrupts it; the
#   agent sends the same round again. Do its tools run twice?
# - parallel_tools_lane: an interactive agent whose two tools each make an AI
#   call (an embedding) run with concurrency: :threads. Which lane do the
#   tools' requests get?
# - persisted_agent_interrupted: as agent_interrupted, with RubyLLM's Rails
#   persistence (chat_model): what an interrupted round leaves in the tables.
class Ai::AsyncAgentGateLiveTest < ActiveSupport::TestCase
  include AsyncSpikeHelper

  MERCHANTS = {
    "NETFLIX.COM 866-579-7172" => "Netflix, Entertainment", "SQ *BLUE BOTTLE COFFEE" => "Blue Bottle Coffee, Dining",
    "AMZN Mktp US*2K4LM0PQ1" => "Amazon, Shopping", "SHELL OIL 57444212500" => "Shell, Fuel",
    "COMCAST CABLE COMM" => "Comcast, Utilities", "PLANET FITNESS CLUB FEE" => "Planet Fitness, Health"
  }.freeze
  CALLS = Concurrent::Array.new   # every tool execution: [tool, argument, lane]

  class LookupMerchant < RubyLLM::Tool
    description "Looks up the merchant name and category for one bank transaction description."
    parameter :description, description: "The transaction description, exactly as given"

    def execute(description:)
      CALLS << [ :lookup_merchant, description, Ai::Transport::SlotInstrumenter.lane ]
      MERCHANTS.fetch(description, "unknown")
    end
  end

  # Runs the tools in the lane the agent was built in: RubyLLM's tool threads
  # start without the job's lane (it's per thread or fiber).
  module CarriesLane
    def initialize(...)
      @ai_lane = Ai::Transport::SlotInstrumenter.lane
      super
    end

    def call(...) = Ai::Transport::SlotInstrumenter.with_lane(@ai_lane) { super }
  end

  # A tool that makes its own AI call: an embedding on the same host's
  # embedding server.
  class EmbedTool < RubyLLM::Tool
    parameter :text, description: "Any short text"

    def execute(text:)
      CALLS << [ name.to_sym, text, Ai::Transport::SlotInstrumenter.lane ]
      endpoint = Ai::Spike::Presets.llama_cpp_embed
      model = Ai::Spike::Model.new(endpoint:, name: "granite-embedding-small-english-r2", embedding_dimensions: 384)
      Ai::Transport::Compatible.new(endpoint).embed([ text ], model:)[:vectors].first.size.to_s
    end
  end

  class EmbedAccounts < EmbedTool
    description "Embeds the text for the accounts index. Returns the vector size."
    def name = "embed_accounts"
  end

  class EmbedCategories < EmbedTool
    description "Embeds the text for the categories index. Returns the vector size."
    def name = "embed_categories"
  end

  def self.llama_context = Ai::Transport.for(AsyncSpikeHelper.llama_route.endpoint).send(:ruby_llm_context)

  class MerchantAgent < RubyLLM::Agent
    context -> { Ai::AsyncAgentGateLiveTest.llama_context }
    model AiSpikeHelper::LLAMA_MODEL, provider: :openai, protocol: :chat_completions, assume_model_exists: true
    instructions "You categorise bank transactions. Look up every transaction with lookup_merchant, " \
                 "then answer with one line per transaction: the description, the merchant, the category, " \
                 "and one sentence on what the purchase likely was."
    tools LookupMerchant
    max_output_tokens 600
  end

  class PersistedMerchantAgent < MerchantAgent
    chat_model Ai::RubyLlmPersistenceLiveTest::SpikePersistence::Chat
  end

  class ParallelToolsAgent < RubyLLM::Agent
    context -> { Ai::AsyncAgentGateLiveTest.llama_context }
    model AiSpikeHelper::LLAMA_MODEL, provider: :openai, protocol: :chat_completions, assume_model_exists: true
    instructions "Call both embed_accounts and embed_categories, in the same turn, then say done."
    tool_options concurrency: :threads
  end

  setup do
    skip "live only: SPIKE_ASYNC=1, SPIKE_LLAMA_CPP_URL and SPIKE_LLAMA_CPP_EMBED_URL" unless ENV["SPIKE_ASYNC"] == "1" && ENV["SPIKE_LLAMA_CPP_URL"].present?
    WebMock.disable!
    CALLS.clear
    @host = URI(ENV.fetch("SPIKE_LLAMA_CPP_URL")).host
    @requests = Concurrent::Array.new
    @subscriber = ActiveSupport::Notifications.monotonic_subscribe("request.ruby_llm") do |_name, start, finish, _id, payload|
      @requests << { lane: Ai::Transport::SlotInstrumenter.lane, url: payload[:url].to_s, start:, finish:, thread: Thread.current.object_id }
    end
  end

  teardown do
    ActiveSupport::Notifications.unsubscribe(@subscriber) if @subscriber
    Ai::Transport::SlotInstrumenter.slots = nil
    WebMock.enable!
  end

  test "agent_interrupted: a chat interrupts a background agent mid-answer; the agent sends the round again" do
    slot = Ai::Spike::LaneSlot.new(1, preempt: true)
    Ai::Transport::SlotInstrumenter.slots = { @host => slot }
    alone = { kind: "chat" }
    Ai::Transport::SlotInstrumenter.with_lane(:interactive) { AsyncSpikeHelper.stream_chat(alone) }

    summary = run_interrupted(MerchantAgent.new)
    summary[:chat_alone_first_chunk_s] = (alone[:first_chunk] - alone[:called]).round(2)
    summary[:slot] = slot.stats
    puts "\n  #{summary.inspect}"
    assert summary[:preempted].positive?, "the chat interrupted the agent"
    assert_equal MERCHANTS.size, summary[:tool_runs], "no tool ran twice"
  end

  test "persisted_agent_interrupted: the same, with RubyLLM's Rails persistence" do
    create_persistence_tables
    slot = Ai::Spike::LaneSlot.new(1, preempt: true)
    Ai::Transport::SlotInstrumenter.slots = { @host => slot }

    record = nil
    # Agent.create! returns the chat record; the agent wraps it.
    summary = run_interrupted(PersistedMerchantAgent.new(chat: PersistedMerchantAgent.create!), on_preempt: lambda { |agent|
      record = agent.chat
      record.messages.reload.map { |m| [ m.role, m.content.to_s.truncate(20), m.respond_to?(:ruby_llm_tool_calls) ? m.ruby_llm_tool_calls.count : 0 ] }
    })
    rows = record.class.find(record.id).messages.order(:created_at)
    summary[:rows_after] = rows.map { [ _1.role, _1.content.to_s.squish.truncate(20) ] }
    summary[:blank_assistant_rows_after] = rows.count { _1.role == "assistant" && _1.content.blank? && _1.ruby_llm_tool_calls.none? }
    puts "\n  #{summary.inspect}"
    assert summary[:preempted].positive?, "the chat interrupted the agent"
    assert_equal MERCHANTS.size, summary[:tool_runs], "no tool ran twice"
  end

  test "parallel_tools_lane: tool threads and the job's lane" do
    results = [ false, true ].to_h do |carry|
      CALLS.clear
      @requests.clear
      tools = [ EmbedAccounts, EmbedCategories ].map { carry ? Class.new(_1) { prepend CarriesLane } : _1 }
      Ai::Transport::SlotInstrumenter.with_lane(:interactive) do
        agent = ParallelToolsAgent.new
        agent.with_tools(*tools.map(&:new))
        agent.chat.add_message(role: :user, content: "Embed the word 'checking' for accounts and 'groceries' for categories.")
        rounds = 0
        rounds += 1 while !agent.complete? && rounds < 6 && agent.step
      end
      [ carry ? :carried : :as_is, {
        tool_lanes: CALLS.map { [ _1[0], _1[2] ] },
        request_lanes: @requests.map { [ _1[:url].split("/").last, _1[:lane] ] },
        tool_threads: @requests.select { _1[:url].include?("embeddings") }.map { _1[:thread] }.uniq.size
      } ]
    end
    puts "\n  #{results.inspect}"
    assert_equal 2, results[:as_is][:tool_lanes].size, "the model called both tools"
  end

  private
    # RubyLLM's install migrations for spike_chats and spike_messages, as in
    # ruby_llm_persistence_live_test, inside this test's transaction: the
    # DDL rolls back with it.
    def create_persistence_tables
      persistence = Ai::RubyLlmPersistenceLiveTest
      ActiveRecord::Migration.suppress_messages do
        %w[create_ruby_llm_records_migration create_chats_migration create_messages_migration].each do |name|
          source = persistence::Template.new(persistence::TEMPLATES.join("#{name}.rb.tt")).render
          klass = source[/class (\w+)/, 1]
          self.class.const_get(klass) rescue self.class.class_eval(source) # rubocop:disable Style/RescueModifier
          self.class.const_get(klass).new.migrate(:up)
        end
      end
      [ persistence::SpikePersistence::Chat, persistence::SpikePersistence::Message, RubyLLM::ActiveRecord::Usage ].each(&:reset_column_information)
      RubyLLM::ActiveRecord::Model.save_to_database
    end

    # Steps the agent in the background lane, interruptible, and sends a
    # chat on another thread once the agent starts writing its final answer
    # (all tools run, first chunk of the next round).
    def run_interrupted(agent, on_preempt: nil)
      chat_record = { kind: "chat" }
      final_started = Concurrent::Event.new
      chat_thread = Thread.new do
        final_started.wait(600)
        sleep 1
        Ai::Transport::SlotInstrumenter.with_lane(:interactive) { AsyncSpikeHelper.stream_chat(chat_record) }
      end

      preempted = 0
      rounds = 0
      at_preempt = nil
      started = clock
      agent.chat.add_message(role: :user, content: "Categorise these transactions:\n#{MERCHANTS.keys.map { "- #{_1}" }.join("\n")}")
      Ai::Transport::SlotInstrumenter.with_lane(:background) do
        Ai::Spike::LaneSlot.with_interrupt do
          until agent.complete? || rounds >= 8
            begin
              agent.step do
                final_started.set if CALLS.size >= MERCHANTS.size
                raise Ai::Spike::LaneSlot::Preempted if Ai::Spike::LaneSlot.interrupt.true?
              end
            rescue Ai::Spike::LaneSlot::Preempted
              preempted += 1
              at_preempt ||= on_preempt&.call(agent)
              retry
            end
            rounds += 1
          end
        end
      end
      final_started.set
      chat_thread.join

      llm = agent.chat.respond_to?(:to_llm) ? agent.chat.to_llm : agent.chat
      answer = llm.messages.last.content.to_s
      {
        agent_s: (clock - started).round(1), steps: rounds, preempted:, tool_runs: CALLS.size,
        tool_calls_in_history: llm.messages.sum { _1.tool_calls.to_h.size },
        answer_names_all: MERCHANTS.values.all? { answer.include?(_1.split(",").first) },
        chat_wait_s: chat_record[:first_chunk] && (chat_record[:first_chunk] - chat_record[:called]).round(2),
        chat_error: chat_record[:error], at_preempt:,
        requests: @requests.map { [ _1[:lane], (_1[:finish] - _1[:start]).round(1) ] }
      }.compact
    end
end
