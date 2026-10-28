require_relative "spike_helper"

# The live tests every local OpenAI-compatible server runs, recorded under
# test/vcr_cassettes/ai/<preset>/. A test class includes this, then calls
# local_server_tests with its preset and model names.
module LocalServerLiveTests
  extend ActiveSupport::Concern
  include AiSpikeHelper

  QUESTION = "How many accounts do I have? Look them up.".freeze

  class_methods do
    attr_reader :preset, :chat_model

    def local_server_tests(preset:, chat_model:)
      @preset, @chat_model = preset, chat_model
      label = Ai::Spike::Presets.public_send(preset).name

      { "ruby_llm" => false, "hand-written" => true }.each do |transport, hand_written|
        test "#{label}: #{transport} generate returns the bill setup in auto mode (live)" do
          events = capture_ai_events do
            with_spike_cassette("#{preset}/generate_#{transport.underscore}") do
              @result = bill_setup.call(route: local_route, hand_written:)
            end
          end

          assert_netflix @result.value
          assert_operator @result.usage.output_tokens, :>, 0
          assert_nil events.sole.payload[:error]
        end
      end

      test "#{label}: a model the server doesn't have is a clean Ai::Error (live)" do
        with_spike_cassette("#{preset}/error_unknown_model") do
          @error = assert_raises(Ai::Error::Refused) { bill_setup.call(route: local_route(name: "no-such-model")) }
        end
        assert_equal unknown_model_status, @error.status
        assert_match(/no-such-model/, @error.message)
      end

      test "#{label}: an oversized prompt (live)" do
        charges = Array.new(3_000) { |i| { date: "2026-01-01", amount: "1.00", name: "CHARGE #{i} AT A STORE WITH A LONG NAME" } }
        generation = Ai::Generations::SuggestBillSetup.new(charges:, categories: CATEGORIES)
        with_spike_cassette("#{preset}/oversized_prompt") do
          @outcome = begin
            generation.call(route: local_route(endpoint: endpoint(json_mode: "json_object")))
          rescue Ai::Error::Base => e
            e
          end
        end
        assert_oversized_prompt @outcome
      end

      test "#{label}: a streamed tool call, run by Sure, then the answer on round two (live)" do
        RubyLLM::Tool.any_instance.expects(:call).never
        chunks = []
        events = capture_ai_events do
          with_spike_cassette("#{preset}/converse_tool_round") do
            @result = Ai::Conversation.new(route: local_route, functions: [ Assistant::Function::GetAccounts.new(users(:family_admin)) ],
                                           max_tool_rounds: 4, turn_timeout: 900,
                                           instructions: "You are a finance assistant. Use tools to look up the user's data. Be brief.")
                                      .respond([ Ai::Transport::Base::Message.new(role: :user, content: QUESTION) ]) { chunks << _1 }
          end
        end

        assert_equal 2, @result.rounds
        assistant, tool = @result.messages[1], @result.messages[2]
        assert_equal [ "get_accounts" ], assistant.tool_calls.map(&:name)
        assert_equal assistant.tool_calls.first.id, tool.tool_call_id
        assert_operator chunks.size, :>, 1, "the answer streams"
        assert @result.text.present?
        assert_equal %w[converse.ai converse.ai], events.map(&:name)
        assert_operator events.last.payload[:usage].input_tokens, :>, 0
      end
    end
  end

  def endpoint(**overrides) = Ai::Spike::Presets.public_send(self.class.preset, **overrides)

  def local_route(endpoint: self.endpoint, name: self.class.chat_model)
    Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint:, name:, max_output_tokens: 2048))
  end
end
