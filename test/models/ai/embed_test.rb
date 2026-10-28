require_relative "spike_helper"

class Ai::EmbedTest < ActiveSupport::TestCase
  include AiSpikeHelper

  test "llama.cpp embedding server returns one vector of the model's dimension per text (live)" do
    endpoint = Ai::Spike::Presets.llama_cpp_embed
    model = Ai::Spike::Model.new(endpoint:, name: "granite-embedding-small-english-r2", embedding_dimensions: 384)
    texts = [ "Netflix monthly subscription", "Electricity bill from the utility" ]

    events = capture_ai_events do
      with_spike_cassette("llama_cpp/embed") do
        @result = Ai::Transport::Compatible.new(endpoint).embed(texts, model:)
      end
    end

    assert_equal 2, @result[:vectors].size
    assert_equal [ 384, 384 ], @result[:vectors].map(&:size)
    assert @result[:vectors].flatten.all?(Float)
    assert_operator @result[:usage].input_tokens, :>, 0
    assert_equal [ "embed.ai" ], events.map(&:name)
  end

  test "one text still comes back as a list of one vector" do
    endpoint = Ai::Spike::Presets.llama_cpp_embed
    model = Ai::Spike::Model.new(endpoint:, name: "granite-embedding-small-english-r2", embedding_dimensions: 384)
    with_spike_cassette("llama_cpp/embed_one") do
      assert_equal [ 384 ], Ai::Transport::Compatible.new(endpoint).embed([ "rent" ], model:)[:vectors].map(&:size)
    end
  end
end
