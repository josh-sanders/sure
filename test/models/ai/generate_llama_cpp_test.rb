require_relative "spike_helper"

# Live on llama.cpp (qwen3.6-35b-a3b-mtp, --jinja), recorded.
class Ai::GenerateLlamaCppTest < ActiveSupport::TestCase
  include AiSpikeHelper

  test "ruby_llm generate returns the bill setup in auto mode" do
    events = capture_ai_events do
      with_spike_cassette("llama_cpp/generate_ruby_llm") do
        result = bill_setup.call(route: llama_route)
        assert_netflix result.value
        assert_operator result.usage.output_tokens, :>, 0
      end
    end

    assert_equal [ "generate.ai" ], events.map(&:name)
    payload = events.first.payload
    assert_equal :bill_setup, payload[:prompt][:metadata][:feature]
    assert_match "CHARGE HISTORY", payload[:prompt][:input]
    assert_equal 15.49, payload[:output]["amount"]
    assert_nil payload[:error]
  end

  test "hand-written generate returns the same suggestion" do
    with_spike_cassette("llama_cpp/generate_hand_written") do
      assert_netflix bill_setup.call(route: llama_route, hand_written: true).value
    end
  end

  test "an inline think block is stripped before parsing" do
    endpoint = Ai::Spike::Presets.llama_cpp(
      json_mode: "none",
      extra_body: { reasoning_format: "none", chat_template_kwargs: { enable_thinking: true } }
    )

    [ false, true ].each do |hand_written|
      with_spike_cassette("llama_cpp/generate_think_#{hand_written ? "hand_written" : "ruby_llm"}") do
        assert_netflix bill_setup.call(route: llama_route(endpoint:), hand_written:).value
      end
    end

    raw = VCR::Cassette.new("ai/llama_cpp/generate_think_ruby_llm", record: :none).send(:previously_recorded_interactions).first
    assert_match "</think>", JSON.parse(raw.response.body).dig("choices", 0, "message", "content")
  end

  test "base URLs with or without /v1 and a trailing slash reach the same path" do
    base = Ai::Spike::Presets.llama_cpp.base_url.delete_suffix("/v1")

    [ base, "#{base}/", "#{base}/v1/" ].each_with_index do |url, index|
      endpoint = Ai::Spike::Presets.llama_cpp(base_url: url, json_mode: "json_object")
      with_spike_cassette("llama_cpp/generate_base_url_#{index}") do
        assert_netflix bill_setup.call(route: llama_route(endpoint:)).value
      end
    end
  end
end
