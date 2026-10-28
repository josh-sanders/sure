require_relative "spike_helper"

# Servers the spike couldn't reach (LM Studio, Ollama, Anthropic, OpenRouter
# weren't set up): WebMock with each provider's documented response shapes
# and error wording. These prove the request each transport builds and the
# fallback policy, not the live server.
class Ai::GenerateStubbedTest < ActiveSupport::TestCase
  include AiSpikeHelper

  NETFLIX = { name: "Netflix", amount: 15.49, frequency: "monthly", day_of_month: 15, weekday: nil, month_of_year: nil,
              category_name: "Entertainment", bill_type: "subscription", autopay: true, confidence: 0.9, rationale: "Monthly." }.freeze
  MOSTLY_NULL = NETFLIX.transform_values { nil }.merge(name: "Netflix").freeze

  def completion(content)
    { status: 200, headers: { "Content-Type" => "application/json" }, body: {
      id: "chatcmpl-1", object: "chat.completion", model: "m",
      choices: [ { index: 0, finish_reason: "stop", message: { role: "assistant", content: } } ],
      usage: { prompt_tokens: 400, completion_tokens: 100, total_tokens: 500 }
    }.to_json }
  end

  def bad_request(message) = { status: 400, headers: { "Content-Type" => "application/json" }, body: { error: { message:, type: "invalid_request_error" } }.to_json }

  def route_for(endpoint, name: "local-model", **route)
    Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint:, name:, max_output_tokens: 2048), **route)
  end

  [ false, true ].each do |hand_written|
    label = hand_written ? "hand-written" : "ruby_llm"

    test "#{label}: LM Studio rejects strict and json_object, auto ends in none mode" do
      stub = stub_request(:post, "http://lmstudio.test/v1/chat/completions").to_return(
        bad_request("Invalid 'response_format.json_schema': 'type' arrays with null are not supported"),
        bad_request("'response_format.type' must be 'json_schema' or 'text'"),
        completion("Here you go:\n```json\n#{NETFLIX.to_json}\n```")
      )

      result = bill_setup.call(route: route_for(Ai::Spike::Presets.lmstudio, reasoning_effort: "low"), hand_written:)

      assert_netflix result.value
      assert_requested stub, times: 3
      first, second, third = request_bodies(%r{lmstudio.test})
      assert_equal "json_schema", first.dig("response_format", "type")
      assert_equal true, first.dig("response_format", "json_schema", "strict")
      assert_equal "low", first["reasoning_effort"]
      assert_equal "json_object", second.dig("response_format", "type")
      assert_nil second["reasoning_effort"], "the 400 retry drops the effort"
      assert_nil third["response_format"]
      assert_match "exactly this shape", third["messages"].first["content"]
      assert_equal "system", third["messages"].first["role"]
    end

    test "#{label}: auto falls back past mostly-null output and keeps the effort" do
      stub_request(:post, "http://lmstudio.test/v1/chat/completions").to_return(
        completion(MOSTLY_NULL.to_json), completion(NETFLIX.to_json)
      )

      assert_netflix bill_setup.call(route: route_for(Ai::Spike::Presets.lmstudio, reasoning_effort: "low"), hand_written:).value
      bodies = request_bodies(%r{lmstudio.test})
      assert_equal %w[json_schema json_object], bodies.map { _1.dig("response_format", "type") }
      assert_equal %w[low low], bodies.map { _1["reasoning_effort"] }
    end

    test "#{label}: Ollama without /v1 is normalised" do
      stub = stub_request(:post, "http://ollama.test/v1/chat/completions").to_return(completion(NETFLIX.to_json))
      assert_netflix bill_setup.call(route: route_for(Ai::Spike::Presets.ollama(base_url: "http://ollama.test/")), hand_written:).value
      assert_requested stub
    end

    test "#{label}: OpenRouter strict mode, model missing from the registry" do
      assert_raises(RubyLLM::ModelNotFoundError) { RubyLLM.models.find("acme/finance-9b-not-real") }
      stub = stub_request(:post, "https://openrouter.ai/api/v1/chat/completions").to_return(completion(NETFLIX.to_json))

      assert_netflix bill_setup.call(route: route_for(Ai::Spike::Presets.openrouter(api_key: "or-key"), name: "acme/finance-9b-not-real"), hand_written:).value
      assert_requested stub
      body = request_bodies(%r{openrouter.ai}).first
      assert_equal "acme/finance-9b-not-real", body["model"]
      assert_equal "json_schema", body.dig("response_format", "type")
    end
  end

  def anthropic_message(content, stop_reason:)
    { status: 200, headers: { "Content-Type" => "application/json" }, body: {
      id: "msg_1", type: "message", role: "assistant", model: "m", content:, stop_reason:, stop_sequence: nil,
      usage: { input_tokens: 500, output_tokens: 120, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 }
    }.to_json }
  end

  def tool_use = { type: "tool_use", id: "toolu_1", name: "bill_setup", input: NETFLIX }

  [ false, true ].each do |hand_written|
    label = hand_written ? "hand-written" : "ruby_llm"

    test "#{label}: Anthropic forces the tool on a model that accepts it" do
      stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(anthropic_message([ tool_use ], stop_reason: "tool_use"))

      route = route_for(Ai::Spike::Presets.anthropic(api_key: "sk-ant"), name: "claude-haiku-4-5")
      assert_netflix bill_setup.call(route:, hand_written:).value

      body = request_bodies(%r{api.anthropic.com}).first
      assert_equal({ "type" => "tool", "name" => "bill_setup", "disable_parallel_tool_use" => true }, body["tool_choice"])
      assert_equal "bill_setup", body.dig("tools", 0, "name")
      assert_equal "object", body.dig("tools", 0, "input_schema", "type")
    end

    test "#{label}: Anthropic auto model answers with text, then calls the tool on the one retry (#4513)" do
      stub = stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(
        anthropic_message([ { type: "text", text: "It looks like a monthly Netflix bill." } ], stop_reason: "end_turn"),
        anthropic_message([ tool_use ], stop_reason: "tool_use")
      )

      route = route_for(Ai::Spike::Presets.anthropic(api_key: "sk-ant"), name: "claude-sonnet-9-9")
      result = bill_setup.call(route:, hand_written:)

      assert_netflix result.value
      assert_requested stub, times: 2
      assert_equal 1000, result.usage.input_tokens, "both attempts are billed"
      first, retried = request_bodies(%r{api.anthropic.com})
      assert_equal "auto", first.dig("tool_choice", "type")
      assert_equal "auto", retried.dig("tool_choice", "type")
      assert_equal %w[user assistant user], retried["messages"].map { _1["role"] }
      assert_match "You did not call the bill_setup tool", retried["messages"].last.to_json
    end
  end
end
