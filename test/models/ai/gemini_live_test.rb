require_relative "spike_helper"

# Live on Google AI Studio's OpenAI-compatible API (a translation layer in
# front of Gemini), recorded. Gemini rejects a function-call round whose
# thought signature is missing, so a third round succeeding is the proof.
class Ai::GeminiLiveTest < ActiveSupport::TestCase
  include AiSpikeHelper

  MODEL = "gemini-3.5-flash-lite".freeze

  def gemini_route(**route)
    Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint: Ai::Spike::Presets.gemini, name: MODEL, max_output_tokens: 4096), **route)
  end

  { "ruby_llm" => false, "hand_written" => true }.each do |label, hand_written|
    test "#{label}: Gemini generates the bill setup in auto mode (live)" do
      with_spike_cassette("gemini/generate_#{label}") do
        assert_netflix bill_setup.call(route: gemini_route, hand_written:).value
      end
      assert_match %r{/v1beta/openai/chat/completions\z}, WebMock::RequestRegistry.instance.requested_signatures.hash.keys.first.uri.to_s
    end
  end

  test "thought signatures survive two tool rounds through Gemini's OpenAI-compatible API (live)" do
    functions = [ Assistant::Function::GetAccounts.new(users(:family_admin)) ]
    conversation = Ai::Conversation.new(
      route: gemini_route(reasoning_effort: "low"), functions:, max_tool_rounds: 4, turn_timeout: 600,
      instructions: "You are a finance assistant. Follow the user's steps exactly, one tool call per step."
    )
    question = "Step 1: call get_accounts. Step 2: after you see the result, call get_accounts again with " \
               "include_balance_series true. Step 3: tell me how many accounts I have."

    with_spike_cassette("gemini/converse_two_rounds") do
      @result = conversation.respond([ Ai::Transport::Base::Message.new(role: :user, content: question) ])
    end

    assert_equal 3, @result.rounds
    assert_equal 2, @result.messages.count { _1.role == :tool }
    assert @result.text.present?

    bodies = request_bodies(%r{generativelanguage})
    sent = bodies.drop(1).map do |body|
      body["messages"].select { _1["role"] == "assistant" }.flat_map { |m| m["tool_calls"].to_a.map { _1.dig("extra_content", "google", "thought_signature") } }
    end
    assert_equal [ 1, 2 ], sent.map(&:size), "every earlier tool call goes back"
    assert sent.flatten.all?(&:present?), "each with its thought signature"
    assert_equal "low", bodies.first["reasoning_effort"]
  end

  test "without its thought signatures, Gemini rejects round two (live)" do
    cassette = YAML.load_file(Rails.root.join("test/vcr_cassettes/ai/gemini/converse_two_rounds.yml"))
    body = JSON.parse(cassette["http_interactions"][1]["request"]["body"]["string"]).merge("stream" => false).except("stream_options")
    body["messages"].each { |message| message["tool_calls"]&.each { _1.delete("extra_content") } }

    with_spike_cassette("gemini/round_two_without_signatures") do
      response = Faraday.new(headers: { "Authorization" => "Bearer #{ENV.fetch("SPIKE_GEMINI_API_KEY", "gemini-key")}" }) { |f| f.request :json; f.response :json }
                        .post("#{Ai::Spike::Presets.gemini.base_url}/chat/completions", body)
      assert_equal 400, response.status
      assert_match "missing a thought_signature", response.body.to_json
    end
  end
end
