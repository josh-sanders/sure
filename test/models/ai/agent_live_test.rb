require_relative "spike_helper"

# Live on OpenClaw 2026.10.8 in a temporary container, its default agent
# running on the llama.cpp server (qwen3.6-35b-a3b-mtp). The gateway token
# and address are filtered out of the cassettes.
class Ai::AgentLiveTest < ActiveSupport::TestCase
  include AiSpikeHelper
  T = Ai::Transport::Base

  def converse(endpoint = Ai::Spike::Presets.openclaw, end_user: "sure-family-spike", &)
    request = T::ConverseRequest.new(
      model: Ai::Spike::Model.new(endpoint:, name: "openclaw"), instructions: nil,
      messages: [ T::Message.new(role: :user, content: "My cat is called Biscuit."),
                  T::Message.new(role: :assistant, content: "Noted!"),
                  T::Message.new(role: :user, content: "What is my cat called? Answer with the name only.") ],
      metadata: { feature: :chat, end_user: }
    )
    Ai::Transport::Compatible.new(endpoint).converse(request, &)
  end

  test "OpenClaw streams the answer from the history; it accepts RubyLLM's stream_options (live)" do
    chunks = []
    with_spike_cassette("openclaw/converse") { @turn = converse { chunks << _1 } }

    assert_match(/Biscuit/, @turn.text)
    assert_equal @turn.text, chunks.join
    assert_empty @turn.tool_calls
    assert_equal [ 0, 0 ], [ @turn.usage.input_tokens, @turn.usage.output_tokens ], "OpenClaw's usage chunk is all zeros"
    body = request_bodies(%r{openclaw\.test|127\.0\.0\.1:18789}).sole
    assert_equal({ "include_usage" => true }, body["stream_options"])
    assert_equal [ "openclaw", true, "sure-family-spike" ], body.values_at("model", "stream", "user")
    assert_equal %w[user assistant user], body["messages"].map { _1["role"] }
    assert_nil body["tools"]
  end

  test "a wrong gateway token is Unauthorized, after one attempt (live)" do
    with_spike_cassette("openclaw/error_bad_token") do
      error = assert_raises(Ai::Error::Unauthorized) { converse(Ai::Spike::Presets.openclaw(api_key: "not-the-token", max_retries: 2)) }
      assert_equal 401, error.status
    end
    assert_equal 1, request_bodies(%r{openclaw\.test|127\.0\.0\.1:18789}).size
  end
end
