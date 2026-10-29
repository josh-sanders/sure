require_relative "spike_helper"

# Each way of turning reasoning down or off, live on the local servers, in
# strict mode so a refusal surfaces instead of the auto fallback hiding it.
# The venus llama.cpp server has thinking off by default, so its rows force
# it on with chat_template_kwargs first. Ollama 0.40.13 runs in a temporary
# container with Qwen3.6-35B-A3B and gpt-oss-20b imported from local GGUFs.
#
# Only one setting turns reasoning off on each: llama.cpp's own
# thinking_budget_tokens: 0, and effort none on Ollama's Qwen3.6. Everything
# else is accepted and ignored, without an error. gpt-oss can't stop
# reasoning, and its effort low only shortens it, at a cost: one run left
# the category null ("no category matches Netflix"), the other the name.
class Ai::ReasoningSwitchesLiveTest < ActiveSupport::TestCase
  include AiSpikeHelper

  SWITCHES = {
    "default" => {},
    "effort_low" => { reasoning_effort: "low" },
    "effort_none" => { reasoning_effort: "none" },
    "enabled_false" => { extra_body: { reasoning: { enabled: false } } }
  }.freeze

  SERVERS = {
    "llama_cpp" => { preset: :llama_cpp, model: LLAMA_MODEL, extra_body: { chat_template_kwargs: { enable_thinking: true } },
                     switches: { "budget_zero" => { extra_body: { thinking_budget_tokens: 0 } } } },
    "ollama_qwen" => { preset: :ollama, model: "qwen3.6-35b-a3b" },
    "ollama_gpt_oss" => { preset: :ollama, model: "gpt-oss-20b" }
  }.freeze

  # The one setting that switches reasoning off on each model.
  OFF = { "llama_cpp" => "budget_zero", "ollama_qwen" => "effort_none" }.freeze

  # [completion tokens, characters of reasoning] for each recorded response.
  def reasoning_of(cassette)
    YAML.load_file(Rails.root.join("test/vcr_cassettes/ai/#{cassette}.yml"))["http_interactions"].map do |interaction|
      body = JSON.parse(interaction["response"]["body"]["string"])
      message = body.dig("choices", 0, "message").to_h
      [ body.dig("usage", "completion_tokens"), (message["reasoning_content"] || message["reasoning"]).to_s.size ]
    end
  end

  SERVERS.each do |server, config|
    SWITCHES.merge(config.fetch(:switches, {})).each do |switch, settings|
      { "ruby_llm" => false, "hand-written" => true }.each do |transport, hand_written|
        test "#{server}: #{transport} with #{switch.tr("_", " ")} (live)" do
          extra_body = config.fetch(:extra_body, {}).merge(settings.fetch(:extra_body, {}))
          endpoint = Ai::Spike::Presets.public_send(config[:preset], json_mode: "strict", extra_body:, timeout_seconds: 900)
          route = Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint:, name: config[:model], max_output_tokens: 6000),
                                       reasoning_effort: settings[:reasoning_effort])
          cassette = "#{config[:preset]}/reasoning_#{server.delete_prefix("ollama_")}_#{switch}_#{transport.underscore}"
          with_spike_cassette(cassette) do
            @outcome = begin
              bill_setup.call(route:, hand_written:)
            rescue Ai::Error::Base => e
              e
            end
          end

          if server == "ollama_gpt_oss" && switch == "effort_low"
            assert_equal [ 15.49, "monthly", 15 ], @outcome.value.values_at(:amount, :frequency, :day_of_month)
            assert_includes [ @outcome.value[:category_name], @outcome.value[:name] ], nil, "less reasoning, one field missed"
          else
            assert_netflix @outcome.value
          end
          body = request_bodies(%r{11434|8180|llama-cpp\.test|ollama\.test}).sole
          assert_equal settings[:reasoning_effort], body["reasoning_effort"]
          assert_equal settings.dig(:extra_body, :reasoning)&.deep_stringify_keys, body["reasoning"]
          reasoning = reasoning_of(cassette).sole.last
          OFF[server] == switch ? assert_equal(0, reasoning) : assert_operator(reasoning, :>, 0, "#{switch} is ignored")
        end
      end
    end
  end
end
