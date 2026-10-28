require_relative "spike_helper"

# Streaming shapes from servers the spike couldn't reach, as WebMock SSE.
class Ai::ConverseStubbedTest < ActiveSupport::TestCase
  include AiSpikeHelper
  T = Ai::Transport::Base

  setup { @functions = [ Assistant::Function::GetAccounts.new(users(:family_admin)) ] }

  def sse(*events, done: true)
    body = events.map { "data: #{_1.to_json}\n\n" }.join + (done ? "data: [DONE]\n\n" : "")
    { status: 200, headers: { "Content-Type" => "text/event-stream" }, body: }
  end

  def delta(delta, finish: nil) = { id: "c1", object: "chat.completion.chunk", model: "m", choices: [ { index: 0, delta:, finish_reason: finish } ] }
  def usage_chunk = { id: "c1", object: "chat.completion.chunk", model: "m", choices: [], usage: { prompt_tokens: 50, completion_tokens: 10, total_tokens: 60 } }
  def answer(text) = sse(delta({ role: "assistant", content: text[0, 5] }), delta({ content: text[5..] }, finish: "stop"), usage_chunk)

  def converse(endpoint, model: "m", rounds: 4)
    route = Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint:, name: model, max_output_tokens: 1024))
    Ai::Conversation.new(route:, functions: @functions, max_tool_rounds: rounds, turn_timeout: 60, instructions: "Be brief.")
                    .respond([ T::Message.new(role: :user, content: "How many accounts?") ])
  end

  test "Ollama style: each tool call arrives whole, without an index" do
    stub_request(:post, "http://ollama.test/v1/chat/completions").to_return(
      sse(delta({ role: "assistant", content: "", tool_calls: [ { id: "call_a", type: "function", function: { name: "get_accounts", arguments: "{}" } } ] }),
          delta({ tool_calls: [ { id: "call_b", type: "function", function: { name: "get_accounts", arguments: "{\"include_balance_series\":false}" } } ] }, finish: "tool_calls"),
          usage_chunk),
      answer("You have several accounts.")
    )

    result = converse(Ai::Spike::Presets.ollama)
    assert_equal %w[call_a call_b], result.messages[1].tool_calls.map(&:id)
    assert_equal({ "include_balance_series" => false }, result.messages[1].tool_calls.last.arguments)
    assert_equal %w[call_a call_b], result.messages.select { _1.role == :tool }.map(&:tool_call_id)
    assert_equal "You have several accounts.", result.text
  end

  test "LM Studio style: arguments arrive in fragments keyed by index" do
    stub_request(:post, "http://lmstudio.test/v1/chat/completions").to_return(
      sse(delta({ role: "assistant", tool_calls: [ { index: 0, id: "1234", type: "function", function: { name: "get_accounts", arguments: "" } } ] }),
          delta({ tool_calls: [ { index: 0, function: { arguments: "{\"include_balance" } } ] }),
          delta({ tool_calls: [ { index: 0, function: { arguments: "_series\": false}" } } ] }, finish: "tool_calls"),
          usage_chunk),
      answer("Three accounts.")
    )

    result = converse(Ai::Spike::Presets.lmstudio)
    assert_equal({ "include_balance_series" => false }, result.messages[1].tool_calls.sole.arguments)
    assert_equal 2, result.rounds
  end

  test "OpenRouter Gemini: reasoning_details survive two tool rounds" do
    sig = ->(data, id) { { type: "reasoning.encrypted", data:, id:, format: "google-gemini-v1", index: 0 } }
    tool_round = ->(call_id, signature) {
      sse(delta({ role: "assistant", content: "", reasoning_details: [ sig.(signature, call_id) ],
                  tool_calls: [ { index: 0, id: call_id, type: "function", function: { name: "get_accounts", arguments: "{}" } } ] }, finish: "tool_calls"),
          usage_chunk)
    }
    stub_request(:post, "https://openrouter.ai/api/v1/chat/completions").to_return(
      tool_round.("tool_1", "SIG-ROUND-1"), tool_round.("tool_2", "SIG-ROUND-2"), answer("Done looking.")
    )

    result = converse(Ai::Spike::Presets.openrouter(api_key: "k"), model: "google/gemini-3-pro-preview")

    assert_equal 3, result.rounds
    _, second, third = request_bodies(%r{openrouter.ai})
    assistant = ->(body) { body["messages"].select { _1["role"] == "assistant" } }
    assert_equal [ "SIG-ROUND-1" ], assistant.(second).map { _1.dig("reasoning_details", 0, "data") }
    assert_equal %w[SIG-ROUND-1 SIG-ROUND-2], assistant.(third).map { _1.dig("reasoning_details", 0, "data") }
    assert_equal [ "Sure" ], WebMock::RequestRegistry.instance.requested_signatures.hash.keys.map { _1.headers["X-Openrouter-Title"] }.uniq
  end

  def anthropic_sse(*events)
    body = events.map { |type, data| "event: #{type}\ndata: #{data.merge(type:).to_json}\n\n" }.join
    { status: 200, headers: { "Content-Type" => "text/event-stream" }, body: }
  end

  test "Anthropic: a streamed tool_use with a thinking signature, run by Sure, answered on round two" do
    usage = { input_tokens: 80, output_tokens: 1 }
    stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(
      anthropic_sse(
        [ "message_start", { message: { id: "msg_1", type: "message", role: "assistant", model: "m", content: [], usage: } } ],
        [ "content_block_start", { index: 0, content_block: { type: "thinking", thinking: "" } } ],
        [ "content_block_delta", { index: 0, delta: { type: "thinking_delta", thinking: "I should look." } } ],
        [ "content_block_delta", { index: 0, delta: { type: "signature_delta", signature: "THINK-SIG" } } ],
        [ "content_block_stop", { index: 0 } ],
        [ "content_block_start", { index: 1, content_block: { type: "tool_use", id: "toolu_1", name: "get_accounts", input: {} } } ],
        [ "content_block_delta", { index: 1, delta: { type: "input_json_delta", partial_json: "{\"include_balance" } } ],
        [ "content_block_delta", { index: 1, delta: { type: "input_json_delta", partial_json: "_series\": false}" } } ],
        [ "content_block_stop", { index: 1 } ],
        [ "message_delta", { delta: { stop_reason: "tool_use" }, usage: { output_tokens: 30 } } ],
        [ "message_stop", {} ]
      ),
      anthropic_sse(
        [ "message_start", { message: { id: "msg_2", type: "message", role: "assistant", model: "m", content: [], usage: } } ],
        [ "content_block_start", { index: 0, content_block: { type: "text", text: "" } } ],
        [ "content_block_delta", { index: 0, delta: { type: "text_delta", text: "You have accounts." } } ],
        [ "content_block_stop", { index: 0 } ],
        [ "message_delta", { delta: { stop_reason: "end_turn" }, usage: { output_tokens: 5 } } ],
        [ "message_stop", {} ]
      )
    )

    result = converse(Ai::Spike::Presets.anthropic(api_key: "k"), model: "claude-sonnet-4-6")

    assert_equal "You have accounts.", result.text
    assert_equal({ "include_balance_series" => false }, result.messages[1].tool_calls.sole.arguments)
    second = request_bodies(%r{api.anthropic.com}).last
    blocks = second["messages"].find { _1["role"] == "assistant" }["content"]
    assert_equal %w[thinking tool_use], blocks.map { _1["type"] }
    assert_equal "THINK-SIG", blocks.first["signature"]
    assert_equal "tool_result", second["messages"].last["content"].first["type"]
  end
end
