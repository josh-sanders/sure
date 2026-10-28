require_relative "spike_helper"

# The external assistant (section 5.6, today's Assistant::External::Client):
# OpenAI chat completions streamed over SSE, with X-Agent-Id and
# X-Session-Key headers, a `user` per family, the history and no tools.
# No agent was running during the spike, so the agent's stream is stubbed.
class Ai::AgentTest < ActiveSupport::TestCase
  include AiSpikeHelper
  T = Ai::Transport::Base

  URL = "http://agent.test:18789/v1/chat/completions".freeze

  def agent_endpoint(**overrides)
    Ai::Spike::Endpoint.new(name: "OpenClaw", protocol: :compatible, preset: :agent, base_url: URL, api_key: "agent-token",
                            agent: true, agent_settings: { agent_id: "main", session_key: "agent:main:main" },
                            timeout_seconds: 120, **overrides)
  end

  def sse(*texts)
    events = texts.map { { id: "c1", object: "chat.completion.chunk", model: "openclaw:main", choices: [ { index: 0, delta: { content: _1 } } ] } }
    { status: 200, headers: { "Content-Type" => "text/event-stream" }, body: events.map { "data: #{_1.to_json}\n\n" }.join + "data: [DONE]\n\n" }
  end

  def history
    [ T::Message.new(role: :user, content: "What did I spend on food?"),
      T::Message.new(role: :assistant, content: "About $410 last month."),
      T::Message.new(role: :user, content: "And the month before?") ]
  end

  def converse(endpoint = agent_endpoint, &)
    model = Ai::Spike::Model.new(endpoint:, name: "openclaw")
    request = T::ConverseRequest.new(model:, instructions: nil, messages: history, metadata: { feature: :chat, end_user: "sure-family-42" })
    Ai::Transport::Compatible.new(endpoint).converse(request, &)
  end

  test "an agent turn streams back text with the agent's headers, the family as user, and no tools" do
    stub_request(:post, URL).to_return(sse("In Sep", "tember you spent ", "$388 on food."))
    chunks = []

    turn = converse { chunks << _1 }

    assert_equal [ "In Sep", "tember you spent ", "$388 on food." ], chunks
    assert_equal "In September you spent $388 on food.", turn.text
    assert_empty turn.tool_calls
    assert_equal [ 0, 0 ], [ turn.usage.input_tokens, turn.usage.output_tokens ], "agents report no tokens"
    assert_requested(:post, URL) do |request|
      body = JSON.parse(request.body)
      request.headers["Authorization"] == "Bearer agent-token" &&
        request.headers["X-Agent-Id"] == "main" && request.headers["X-Session-Key"] == "agent:main:main" &&
        body["model"] == "openclaw" && body["stream"] == true && body["user"] == "sure-family-42" &&
        !body.key?("tools") && !body.key?("safety_identifier") &&
        body["messages"].map { _1["role"] } == %w[user assistant user] &&
        body["stream_options"] == { "include_usage" => true }   # RubyLLM always adds it; today's client doesn't
    end
  end

  test "an agent that's down is Unreachable, and a 5xx is Upstream, after one attempt" do
    stub_request(:post, URL).to_raise(Errno::ECONNREFUSED)
    assert_raises(Ai::Error::Unreachable) { converse }

    WebMock.reset!
    stub = stub_request(:post, URL).to_return(status: 502, body: "Bad Gateway")
    assert_raises(Ai::Error::Upstream) { converse }
    assert_requested stub, times: 1
  end

  test "with retries on the endpoint, a refused connection is retried before the stream starts" do
    stub = stub_request(:post, URL).to_raise(Faraday::ConnectionFailed.new("refused")).then.to_return(sse("Hi."))
    assert_equal "Hi.", converse(agent_endpoint(max_retries: 2)).text
    assert_requested stub, times: 2
  end
end
