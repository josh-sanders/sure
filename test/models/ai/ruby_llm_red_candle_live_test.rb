require_relative "spike_helper"

# Spike: RubyLLM::RedCandle runs a quantized GGUF model inside the Ruby
# process (Candle, CPU here), against the plan's local inference through
# llama.cpp, Ollama or LM Studio as servers (§4.2). For in process: no
# server to run, nothing leaves the process. Against: each Puma or Sidekiq
# process that loads it holds the model in memory and competes for the
# CPU with the web and job work it was there to do.
#
# Live only (SPIKE_RED_CANDLE=1): it downloads the model from Hugging Face
# and runs on the CPU, so it isn't part of the replayed suite.
class Ai::RubyLlmRedCandleLiveTest < ActiveSupport::TestCase
  include AiSpikeHelper

  MODEL = "Qwen/Qwen2.5-1.5B-Instruct-GGUF".freeze

  def rss_mb = File.read("/proc/self/status")[/VmRSS:\s+(\d+)/, 1].to_i / 1024

  # The plugin installs (ruby_llm >= 1.10, < 3.0) but can't load on 2.x.
  test "ruby_llm-red_candle 0.2.1 fails to load on RubyLLM 2.1.1" do
    error = assert_raises(NameError) { require "ruby_llm-red_candle" }
    assert_match "RubyLLM::Model::Info", error.message, "a 1.x class 2.x removed"
  end

  # So the in-process question is tested through Red Candle itself.
  test "Red Candle: bill setup with Sure's schema, on a 1.5B model inside the test process (live)" do
    skip "live only: SPIKE_RED_CANDLE=1" unless ENV["SPIKE_RED_CANDLE"] == "1"
    require "candle"

    generation = bill_setup
    schema = Ai::Generations::SuggestBillSetup.output_schema
    prompt = "#{generation.send(:rendered_prompt)}\n\n#{generation.input}"
    before = rss_mb
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    llm = Candle::LLM.from_pretrained(MODEL, gguf_file: "qwen2.5-1.5b-instruct-q4_k_m.gguf")
    loaded = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = begin
      llm.generate_structured(prompt, schema: schema.deep_stringify_keys)
    rescue => e
      e
    end
    finished = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    value = result.is_a?(Exception) ? nil : Ai::Schema.coerce(result.is_a?(String) ? JSON.parse(result) : result, schema)
    summary = { load_s: (loaded - started).round(1), answer_s: (finished - loaded).round(1), rss_gain_mb: rss_mb - before,
                result: result.is_a?(Exception) ? "#{result.class}: #{result.message.truncate(160)}" : value&.slice(:amount, :frequency, :day_of_month, :category_name) }
    puts "\n  red candle: #{summary.inspect}"
    assert summary[:rss_gain_mb].positive?
  end
end
