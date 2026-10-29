require_relative "spike_helper"

# Live on OpenRouter's chat completions with free models, recorded. The key
# has never bought credits, so paid models answer 402. Free models share an
# upstream pool, so any of them can answer 429 for a while: Xing 4.0 did,
# three times, mapped to RateLimited, then recovered before it was recorded.
# Flint 1.0 and Nemotron 3.5 Lightning's free variant both reason before they
# answer; Lightning's doesn't list response_format at all.
class Ai::OpenrouterChatLiveTest < ActiveSupport::TestCase
  include AiSpikeHelper

  FLINT = "recursive/flint-v1.0:free".freeze
  LIGHTNING = "nvidia/nemotron-3.5-lightning:free".freeze
  LIGHTNING_PAID = "nvidia/nemotron-3.5-lightning".freeze

  def openrouter(**overrides) = Ai::Spike::Presets.openrouter(api_key: ENV.fetch("SPIKE_OPENROUTER_API_KEY", "or-key"), **overrides)

  def openrouter_route(name, endpoint: openrouter(max_retries: 0))
    Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint:, name:, max_output_tokens: 4096))
  end

  def sent = request_bodies(%r{openrouter\.ai})

  { "ruby_llm" => false, "hand-written" => true }.each do |transport, hand_written|
    test "OpenRouter: #{transport} generate in strict mode on a free model (live)" do
      with_spike_cassette("openrouter/generate_#{transport.underscore}") do
        @result = bill_setup.call(route: openrouter_route(FLINT), hand_written:)
      end

      assert_netflix @result.value
      assert_operator @result.usage.output_tokens, :>, 0
      assert_equal [ [ FLINT, "json_schema", true ] ], sent.map { [ _1["model"], _1.dig("response_format", "type"), _1.dig("response_format", "json_schema", "strict") ] }
      assert_equal %w[system user], sent.sole["messages"].map { _1["role"] }
    end
  end

  test "OpenRouter: strict mode on a free model that doesn't list response_format (live)" do
    with_spike_cassette("openrouter/generate_unlisted_strict") do
      @result = bill_setup.call(route: openrouter_route(LIGHTNING))
    end

    assert_netflix @result.value
    assert_equal [ "json_schema" ], sent.map { _1.dig("response_format", "type") }
  end

  # Reasoning tokens from each recorded response, for the effort tests.
  def reasoning_tokens(cassette)
    YAML.load_file(Rails.root.join("test/vcr_cassettes/ai/openrouter/#{cassette}.yml"))["http_interactions"]
        .map { JSON.parse(_1["response"]["body"]["string"])["usage"] }
        .map { [ _1["completion_tokens"], _1.dig("completion_tokens_details", "reasoning_tokens") ] }
  end

  # Effort low barely moves either model (one sample each, and the defaults
  # vary by 2x run to run). Effort none switches Nemotron's reasoning off;
  # Flint's endpoint refuses it with a 400.
  { "flint" => FLINT, "lightning" => LIGHTNING }.each do |short, model|
    %w[low none].each do |effort|
      { "ruby_llm" => false, "hand-written" => true }.each do |transport, hand_written|
        test "OpenRouter: #{transport} #{short} with reasoning effort #{effort} (live)" do
          cassette = "effort_#{short}_#{effort}_#{transport.underscore}"
          route = Ai::Spike::Route.new(model: openrouter_route(model).model, reasoning_effort: effort)
          with_spike_cassette("openrouter/#{cassette}") do
            @outcome = begin
              bill_setup.call(route:, hand_written:)
            rescue Ai::Error::Base => e
              e
            end
          end

          body = sent.sole
          assert_equal effort, hand_written ? body["reasoning_effort"] : body.dig("reasoning", "effort")
          if short == "flint" && effort == "none"
            assert_equal [ Ai::Error::Refused, 400 ], [ @outcome.class, @outcome.status ]
            assert_equal "Reasoning is mandatory for this endpoint and cannot be disabled.", @outcome.message
          else
            assert_netflix @outcome.value
            reasoning = reasoning_tokens(cassette).sole.last
            effort == "none" ? assert_equal(0, reasoning) : assert_operator(reasoning, :>, 400)
          end
        end
      end
    end
  end

  # OpenRouter's own switch, which a route can't express: an operator would
  # put it in the endpoint's extra_body, which both transports send as given.
  # It behaves exactly like effort none on both models.
  { "flint" => FLINT, "lightning" => LIGHTNING }.each do |short, model|
    { "ruby_llm" => false, "hand-written" => true }.each do |transport, hand_written|
      test "OpenRouter: #{transport} #{short} with reasoning enabled false (live)" do
        cassette = "reasoning_off_#{short}_#{transport.underscore}"
        endpoint = openrouter(max_retries: 0, extra_body: { reasoning: { enabled: false } })
        with_spike_cassette("openrouter/#{cassette}") do
          @outcome = begin
            bill_setup.call(route: openrouter_route(model, endpoint:), hand_written:)
          rescue Ai::Error::Base => e
            e
          end
        end

        assert_equal({ "enabled" => false }, sent.sole["reasoning"])
        if short == "flint"
          assert_equal [ Ai::Error::Refused, 400 ], [ @outcome.class, @outcome.status ]
          assert_equal "Reasoning is mandatory for this endpoint and cannot be disabled.", @outcome.message
        else
          assert_netflix @outcome.value
          assert_equal 0, reasoning_tokens(cassette).sole.last
        end
      end
    end
  end

  test "OpenRouter: a streamed tool call, run by Sure, then the answer on round two (live)" do
    RubyLLM::Tool.any_instance.expects(:call).never
    chunks = []
    with_spike_cassette("openrouter/converse_tool_round") do
      @result = Ai::Conversation.new(route: openrouter_route(LIGHTNING), functions: [ Assistant::Function::GetAccounts.new(users(:family_admin)) ],
                                     max_tool_rounds: 4, turn_timeout: 300,
                                     instructions: "You are a finance assistant. Use tools to look up the user's data. Be brief.")
                                .respond([ Ai::Transport::Base::Message.new(role: :user, content: "How many accounts do I have? Look them up.") ]) { chunks << _1 }
    end

    assert_equal 2, @result.rounds
    assistant, tool = @result.messages[1], @result.messages[2]
    assert_equal [ "get_accounts" ], assistant.tool_calls.map(&:name)
    assert_equal assistant.tool_calls.first.id, tool.tool_call_id
    assert_operator chunks.size, :>, 1, "the answer streams"
    assert @result.text.present?
    assert_equal [ "Sure" ], WebMock::RequestRegistry.instance.requested_signatures.hash.keys.map { _1.headers["X-Openrouter-Title"] }.uniq
    first, second = sent
    assert_equal [ %w[system user], %w[system user assistant tool] ], [ first, second ].map { |body| body["messages"].map { _1["role"] } }
    reasoning = second["messages"].find { _1["role"] == "assistant" }["reasoning_details"]
    assert reasoning.present?, "round two sends the model's reasoning_details back"
  end

  test "OpenRouter: a paid model on a key without credits is a 402, after one request (live)" do
    with_spike_cassette("openrouter/error_no_credits") do
      @error = assert_raises(Ai::Error::Base) do
        bill_setup.call(route: openrouter_route(LIGHTNING_PAID, endpoint: openrouter(max_retries: 2)))
      end
    end

    assert_equal [ Ai::Error::Refused, 402 ], [ @error.class, @error.status ]
    assert_match "Insufficient credits", @error.message
    assert_equal 1, sent.size
  end

  test "OpenRouter: a wrong key is Unauthorized (live)" do
    with_spike_cassette("openrouter/error_bad_key") do
      @error = assert_raises(Ai::Error::Base) do
        bill_setup.call(route: openrouter_route(FLINT, endpoint: openrouter(api_key: "sk-or-v1-not-a-key", max_retries: 2)))
      end
    end

    assert_equal [ Ai::Error::Unauthorized, 401 ], [ @error.class, @error.status ]
    assert_equal 1, sent.size
  end
end
