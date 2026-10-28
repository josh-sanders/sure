require_relative "spike_helper"

# Live on opencode's Zen gateway (https://opencode.ai/zen/v1/systemone,
# jev-1.13-free, OpenCode's anonymous key "public"), recorded. Its path matches what RubyLLM's
# typesafe provider always posts to: <base>/v1/systemone.
class Ai::JudgeJevLiveTest < ActiveSupport::TestCase
  include AiSpikeHelper

  BASE = "https://opencode.ai/zen".freeze
  MODEL = "jev-1.13-free".freeze
  STATE = { description: "NETFLIX.COM AUTOPAY", amount: "15.49", classification: "expense" }.freeze

  test "RubyLLM's judge answers probability, choice and score over Jev's protocol (live)" do
    context = RubyLLM.context { |c| c.typesafe_api_key = "public"; c.typesafe_api_base = BASE; c.max_retries = 0 }
    questions = {
      subscription: { type: :probability, instructions: "Is this a recurring subscription?" },
      category: { type: :choice, instructions: "Which spending category fits this transaction?",
                  options: { "Entertainment" => "Streaming, games, events", "Utilities" => "Power, water, internet", "Groceries" => nil } },
      recurring: { type: :score, instructions: "How clearly is this a recurring charge?",
                   levels: [ "Clearly one-off", "Unclear", "Clearly recurring" ] }
    }

    with_spike_cassette("jev/judge_ruby_llm") do
      @judgment = context.judge(STATE, questions:, model: MODEL, provider: :typesafe, assume_model_exists: true)
    end

    assert_operator @judgment.answers[:subscription].probability, :>, 0.8
    assert_equal "Entertainment", @judgment.answers[:category].choice
    assert_operator @judgment.answers[:category].probabilities["Entertainment"], :>, 0.8
    assert_operator @judgment.answers[:recurring].score, :>, 1
    assert_operator @judgment.tokens.input, :>, 0

    body = request_bodies(%r{opencode.ai}).sole
    assert_equal STATE.stringify_keys, body["state"], "Jev's transaction object goes as the state"
    assert_equal({ "subscription" => "noul", "category" => "choice", "recurring" => "score" }, body["questions"].transform_values { _1["type"] })
    assert_equal "https://opencode.ai/zen/v1/systemone", WebMock::RequestRegistry.instance.requested_signatures.hash.keys.sole.uri.to_s.sub(":443", "")
  end

  test "Sure's Provider::Jev gets the same answer from the same endpoint (live)" do
    jev = Provider::Jev.new("public", endpoint: "#{BASE}/v1/systemone", model: MODEL)
    questions = { category: { type: "choice", instructions: "Which spending category fits this transaction?",
                              criteria: { "Entertainment" => "Streaming, games, events", "Utilities" => "Power, water, internet", "Groceries" => nil } } }

    with_spike_cassette("jev/judge_provider_jev") do
      @response = jev.decide(state: STATE, questions:)
    end

    assert @response.success?, @response.error&.message
    assert_equal "Entertainment", @response.data[:category].value
  end
end
