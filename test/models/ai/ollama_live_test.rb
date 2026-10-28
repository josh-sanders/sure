require_relative "local_server_live_tests"

# Live on Ollama 0.40.12 in a temporary container, CPU only, with
# Qwen3-30B-A3B-Instruct-2507 (Q4_K_M) and granite-embedding-small-english-r2
# imported from local GGUF files. SPIKE_OLLAMA_URL has no /v1, so every test
# also covers the normaliser.
class Ai::OllamaLiveTest < ActiveSupport::TestCase
  include LocalServerLiveTests

  local_server_tests preset: :ollama, chat_model: "qwen3-30b-a3b-instruct"

  def unknown_model_status = 404

  # Ollama 0.40 refuses rather than truncating, in llama.cpp's wording.
  def assert_oversized_prompt(outcome)
    assert_kind_of Ai::Error::ContextTooLong, outcome
    assert_match(/exceeds the available context size \(8192 tokens\)/, outcome.message)
  end

  test "Ollama: embeddings return one vector of the model's dimension per text (live)" do
    model = Ai::Spike::Model.new(endpoint:, name: "granite-embedding-small-english-r2", embedding_dimensions: 384)
    with_spike_cassette("ollama/embed") do
      @result = Ai::Transport::Compatible.new(endpoint).embed([ "Netflix monthly subscription", "Electricity bill" ], model:)
    end

    assert_equal [ 384, 384 ], @result[:vectors].map(&:size)
    assert_operator @result[:usage].input_tokens, :>, 0
  end
end
