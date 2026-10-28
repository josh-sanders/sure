require_relative "local_server_live_tests"

# Live on LM Studio's headless daemon (llmster 0.0.25, llama.cpp engine
# 2.41.0) in a temporary container, CPU only, with
# Qwen3-30B-A3B-Instruct-2507 (Q4_K_M) imported by symlink from a local GGUF
# and loaded with an 8,192-token context. SPIKE_LMSTUDIO_URL has no /v1.
class Ai::LmstudioLiveTest < ActiveSupport::TestCase
  include LocalServerLiveTests

  # json_object is refused before the context check (see the mode tests).
  local_server_tests preset: :lmstudio, chat_model: "qwen3-30b-a3b-instruct", oversized_json_mode: "strict"

  # LM Studio answers with the model it has loaded, whatever the request
  # names, so a mistyped model name never fails.
  def assert_unknown_model(outcome)
    assert_kind_of Ai::Generation::Result, outcome
    assert_netflix outcome.value
  end

  # LM Studio wraps its llama.cpp engine's 400 in its own message.
  def assert_oversized_prompt(outcome)
    assert_kind_of Ai::Error::ContextTooLong, outcome
    assert_match(/Engine protocol predict request returned 400: .*exceed_context_size_error/, outcome.message)
  end

  def generate_in(mode, hand_written:)
    model = Ai::Spike::Model.new(endpoint: endpoint(json_mode: mode), name: self.class.chat_model, max_output_tokens: 2048)
    bill_setup.call(route: Ai::Spike::Route.new(model:, reasoning_effort: "low"), hand_written:)
  end

  def sent = request_bodies(%r{lmstudio\.test|127\.0\.0\.1:1234}).map { [ _1.dig("response_format", "type"), _1["reasoning_effort"] ] }

  { "ruby_llm" => false, "hand-written" => true }.each do |transport, hand_written|
    test "LM Studio: #{transport} strict mode and reasoning effort are accepted (live)" do
      with_spike_cassette("lmstudio/mode_strict_#{transport.underscore}") { assert_netflix generate_in("strict", hand_written:).value }
      assert_equal [ [ "json_schema", "low" ] ], sent
    end

    test "LM Studio: #{transport} json_object is Refused, in LM Studio's string error shape (live)" do
      with_spike_cassette("lmstudio/mode_json_object_#{transport.underscore}") do
        error = assert_raises(Ai::Error::Refused) { generate_in("json_object", hand_written:) }
        assert_equal "'response_format.type' must be 'json_schema' or 'text'", error.message
        assert_equal 400, error.status
      end
      assert_equal [ [ "json_object", "low" ] ], sent
    end

    test "LM Studio: #{transport} none mode parses the prompted shape (live)" do
      with_spike_cassette("lmstudio/mode_none_#{transport.underscore}") { assert_netflix generate_in("none", hand_written:).value }
      assert_equal [ [ nil, "low" ] ], sent
    end
  end
end
