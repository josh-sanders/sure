require_relative "spike_helper"

# Spike: Anthropic direct, live, on a key with no credits. Every request that
# reaches a model, count_tokens included, gets a 400 invalid_request_error
# ("Your credit balance is too low…"), not a 402, so only the error paths
# run. The model list (GET /v1/models) answers 200.
class Ai::AnthropicLiveTest < ActiveSupport::TestCase
  include AiSpikeHelper

  MODEL = "claude-haiku-5-5".freeze

  def route(name = MODEL, api_key: ENV.fetch("SPIKE_ANTHROPIC_API_KEY", "sk-ant"))
    endpoint = Ai::Spike::Presets.anthropic(api_key:, max_retries: 2)
    Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint:, name:, max_output_tokens: 1024))
  end

  def attempt
    yield
    flunk "expected an Ai::Error"
  rescue Ai::Error::Base => e
    e
  end

  def anthropic_requests = request_bodies(%r{api\.anthropic\.com(:443)?/v1/messages})

  { "ruby_llm" => false, "hand-written" => true }.each do |transport, hand_written|
    test "#{transport}: no credits is a 400, mapped to Refused, after one request (live)" do
      with_spike_cassette("anthropic/no_credits_generate_#{transport.underscore}") do
        @error = attempt { bill_setup.call(route: route, hand_written:) }
      end

      assert_kind_of Ai::Error::Refused, @error
      assert_equal 400, @error.status
      assert_match(/credit balance is too low/, @error.message)
      assert_equal 1, anthropic_requests.size, "max_retries 2, and a 400 isn't retried"
      # RubyLLM tells an empty balance apart, by the message; the anthropic gem can't.
      expected_cause = hand_written ? ::Anthropic::Errors::BadRequestError : RubyLLM::PaymentRequiredError
      assert_kind_of expected_cause, @error.cause
    end

    test "#{transport}: a wrong key is Unauthorized, after one request (live)" do
      with_spike_cassette("anthropic/bad_key_#{transport.underscore}") do
        @error = attempt { bill_setup.call(route: route(api_key: "sk-ant-not-a-key"), hand_written:) }
      end

      assert_kind_of Ai::Error::Unauthorized, @error
      assert_equal 401, @error.status
      assert_equal 1, anthropic_requests.size
    end
  end

  test "ruby_llm: a streamed chat turn with a tool gets the same 400 (live)" do
    with_spike_cassette("anthropic/no_credits_converse") do
      @error = attempt do
        Ai::Conversation.new(route:, functions: [ Assistant::Function::GetAccounts.new(users(:family_admin)) ],
                             max_tool_rounds: 2, turn_timeout: 60, instructions: "Be brief.")
                        .respond([ Ai::Transport::Base::Message.new(role: :user, content: "How many accounts do I have?") ])
      end
    end

    assert_kind_of Ai::Error::Refused, @error
    assert_kind_of RubyLLM::PaymentRequiredError, @error.cause
    body = anthropic_requests.sole
    assert body["stream"]
    assert_equal [ "get_accounts" ], body["tools"].map { _1["name"] }
  end

  test "ruby_llm: an unknown model gets the balance error first (live)" do
    with_spike_cassette("anthropic/no_credits_unknown_model") do
      @error = attempt { bill_setup.call(route: route("claude-not-a-model")) }
    end

    assert_kind_of Ai::Error::Refused, @error
    assert_match(/credit balance is too low/, @error.message, "so a health check on this key can't tell a bad model name")
  end
end
