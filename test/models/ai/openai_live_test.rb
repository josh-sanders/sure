require_relative "spike_helper"

# Spike: OpenAI direct, live, on a key with no credits. Chat completions, the
# Responses API and embeddings all answer 429 insufficient_quota
# (credit_balance_exhausted): "You have no credits remaining." GET /v1/models
# and listing vector stores answer 200.
class Ai::OpenaiLiveTest < ActiveSupport::TestCase
  include AiSpikeHelper

  MODEL = "gpt-5-mini".freeze
  # RubyLLM retries every 429, a spent balance included: nothing in its
  # error patterns tells OpenAI's insufficient_quota from a rate limit.
  # ruby-openai doesn't retry.
  EXPECTED_REQUESTS = { "responses" => 3, "chat_ruby_llm" => 3, "chat_hand_written" => 1, "embed" => 3 }.freeze

  def endpoint(**overrides) = Ai::Spike::Presets.openai(api_key: ENV.fetch("SPIKE_OPENAI_API_KEY", "sk-openai"), max_retries: 2, **overrides)

  def route(**overrides) = Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint: endpoint(**overrides), name: MODEL, max_output_tokens: 1024))

  def attempt
    yield
    flunk "expected an Ai::Error"
  rescue Ai::Error::Base => e
    e
  end

  def openai_requests = WebMock::RequestRegistry.instance.requested_signatures.hash.select { |sig, _| sig.uri.to_s.match?(%r{api\.openai\.com}) }.values.sum

  {
    "ruby_llm, Responses API" => [ "responses", {}, false ],
    "ruby_llm, chat completions" => [ "chat_ruby_llm", { responses_api: false }, false ],
    "hand-written, chat completions" => [ "chat_hand_written", { responses_api: false }, true ]
  }.each do |label, (cassette, overrides, hand_written)|
    test "#{label}: no credits is a 429 insufficient_quota (live)" do
      with_spike_cassette("openai/no_credits_#{cassette}") do
        @error = attempt { bill_setup.call(route: route(**overrides), hand_written:) }
      end

      assert_kind_of Ai::Error::RateLimited, @error
      assert_equal 429, @error.status
      assert_match(/no credits remaining/, @error.message)
      assert_equal EXPECTED_REQUESTS.fetch(cassette), openai_requests, "with max_retries 2"
    end
  end

  test "ruby_llm: embed with no credits is the same 429 (live)" do
    with_spike_cassette("openai/no_credits_embed") do
      @error = attempt { Ai::Transport.for(endpoint(responses_api: false)).embed([ "Netflix" ], model: Ai::Spike::Model.new(endpoint: endpoint, name: "text-embedding-3-small")) }
    end

    assert_kind_of Ai::Error::RateLimited, @error
    assert_equal EXPECTED_REQUESTS.fetch("embed"), openai_requests
  end

  { "ruby_llm" => false, "hand-written" => true }.each do |transport, hand_written|
    test "#{transport}: a wrong key is Unauthorized, after one request (live)" do
      with_spike_cassette("openai/bad_key_#{transport.underscore}") do
        @error = attempt { bill_setup.call(route: route(api_key: "sk-not-a-key", responses_api: false), hand_written:) }
      end

      assert_kind_of Ai::Error::Unauthorized, @error
      assert_equal 1, openai_requests
    end
  end
end
