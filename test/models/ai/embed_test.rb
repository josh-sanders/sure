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

  test "a gateway that returns fewer vectors than texts is InvalidOutput (RubyLLM 2.1.1 doesn't check, #1269)" do
    stub_request(:post, "http://llama-cpp-embed.test/v1/embeddings").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { data: [ { index: 0, embedding: Array.new(384, 0.1) } ], usage: { prompt_tokens: 4 } }.to_json
    )
    endpoint = Ai::Spike::Presets.llama_cpp_embed(base_url: "http://llama-cpp-embed.test/v1")
    model = Ai::Spike::Model.new(endpoint:, name: "granite-embedding-small-english-r2")
    assert_raises(Ai::Error::InvalidOutput) { Ai::Transport::Compatible.new(endpoint).embed(%w[a b c], model:) }
  end
end
