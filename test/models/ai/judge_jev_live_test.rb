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

  # Packing: several transactions in one state, one choice question each.
  # judge takes any Hash as the state and any number of questions, so this
  # needs no support from RubyLLM beyond what it has; it has no helper for it.
  test "RubyLLM's judge answers eight transactions packed into one request (live)" do
    truth = { "t1" => [ "NETFLIX.COM AUTOPAY", "Entertainment" ], "t2" => [ "PG&E WEB ONLINE PAYMENT", "Utilities" ],
              "t3" => [ "WHOLE FOODS MARKET #10233", "Groceries" ], "t4" => [ "UBER *TRIP HELP.UBER.COM", "Transport" ],
              "t5" => [ "SPOTIFY USA", "Entertainment" ], "t6" => [ "COMCAST XFINITY", "Utilities" ],
              "t7" => [ "TRADER JOE'S #552", "Groceries" ], "t8" => [ "SHELL OIL 57444", "Transport" ] }
    options = %w[Entertainment Utilities Groceries Transport].to_h { [ _1, nil ] }
    state = truth.transform_values { |(description, _)| { description:, amount: "25.00", classification: "expense" } }
    questions = truth.keys.to_h do |id|
      [ id.to_sym, { type: :choice, instructions: "Which spending category best fits bank transaction #{id} in the state?", options: } ]
    end
    context = RubyLLM.context { |c| c.typesafe_api_key = "public"; c.typesafe_api_base = BASE; c.max_retries = 0 }

    with_spike_cassette("jev/judge_ruby_llm_packed") do
      @judgment = context.judge(state, questions:, model: MODEL, provider: :typesafe, assume_model_exists: true)
    end

    assert_equal truth.transform_values(&:last), @judgment.answers.to_h { |name, answer| [ name.to_s, answer.choice ] }
    body = request_bodies(%r{opencode.ai}).sole
    assert_equal truth.keys, body["state"].keys
    assert_equal 8, body["questions"].size
  end
end
