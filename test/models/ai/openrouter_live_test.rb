require_relative "spike_helper"

# Live on OpenRouter's decisions gateway (/api/alpha/decisions), recorded,
# with Respan Span-01 Lite: a decisions model on Jev's protocol. The paid
# variant needs credits this key doesn't have, so the free one is used.
class Ai::OpenrouterLiveTest < ActiveSupport::TestCase
  include AiSpikeHelper

  RESPAN_FREE = "respan/span-01-lite:free".freeze
  DECISIONS = "https://openrouter.ai/api/alpha/decisions".freeze

  def key = ENV.fetch("SPIKE_OPENROUTER_API_KEY", "or-key")

  test "RubyLLM's judge can't reach OpenRouter's decisions endpoint (live)" do
    questions = { subscription: { type: :probability, instructions: "Is this a recurring subscription?" } }
    typesafe = RubyLLM.context { |c| c.typesafe_api_key = key; c.typesafe_api_base = "https://openrouter.ai/api/alpha"; c.max_retries = 0 }
    openai = RubyLLM.context { |c| c.openai_api_key = key; c.openai_api_base = "https://openrouter.ai/api/alpha"; c.max_retries = 0 }

    with_spike_cassette("openrouter/judge_ruby_llm") do
      # System One payload (Jev's), but a fixed path: <base>/v1/systemone.
      error = assert_raises(RubyLLM::Error) { typesafe.judge("NETFLIX 15.49", questions:, model: RESPAN_FREE, provider: :typesafe, assume_model_exists: true) }
      assert_match "Not Found", error.message
      # Right path, but the OpenAI Decisions payload (input + a question array).
      assert_raises(RubyLLM::BadRequestError) { openai.judge("NETFLIX 15.49", questions:, model: RESPAN_FREE, provider: :openai, assume_model_exists: true) }
    end
    assert_equal %w[/api/alpha/v1/systemone /api/alpha/decisions],
                 WebMock::RequestRegistry.instance.requested_signatures.hash.keys.map { _1.uri.path }
  end

  test "a hand-written judge reaches the gateway; Respan wants a string state, not Jev's object (live)" do
    post = ->(body) {
      Faraday.new { |f| f.request :json; f.response :json }
             .post(DECISIONS, body.merge(model: RESPAN_FREE), "Authorization" => "Bearer #{key}")
    }
    noul = { subscription: { type: "noul", instructions: "Is this a recurring subscription?" } }

    with_spike_cassette("openrouter/judge_hand_written") do
      ok = post.(state: "NETFLIX.COM AUTOPAY 15.49 on the 15th of each month", questions: noul)
      assert_equal 200, ok.status
      assert_operator ok.body.dig("answers", "subscription", "noul"), :>, 0.9

      jev_state = post.(state: { description: "NETFLIX.COM AUTOPAY", amount: "15.49" }, questions: noul)
      assert_equal 400, jev_state.status
      assert_match "state must be a string", jev_state.body.dig("error", "message")
    end
  end
end
