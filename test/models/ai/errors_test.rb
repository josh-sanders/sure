require_relative "spike_helper"

class Ai::ErrorsTest < ActiveSupport::TestCase
  include AiSpikeHelper

  def stub_route(endpoint, name: "local-model") = Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint:, name:))

  def json_error(status, message, type = "error")
    { status:, headers: { "Content-Type" => "application/json" }, body: { error: { message:, type: } }.to_json }
  end

  def anthropic_error(status, message, type)
    { status:, headers: { "Content-Type" => "application/json" }, body: { type: "error", error: { type:, message: } }.to_json }
  end

  BOTH = { "ruby_llm" => false, "hand-written" => true }.freeze

  # Live, recorded ---------------------------------------------------------

  BOTH.each do |label, hand_written|
    test "#{label}: a bad key on llama.cpp is Unauthorized (live)" do
      endpoint = Ai::Spike::Presets.llama_cpp(api_key: "not-the-key", json_mode: "json_object")
      with_spike_cassette("llama_cpp/error_bad_key_#{label.underscore}") do
        assert_raises(Ai::Error::Unauthorized) { bill_setup.call(route: llama_route(endpoint:), hand_written:) }
      end
    end

    test "#{label}: an oversized prompt on llama.cpp is ContextTooLong (live)" do
      charges = Array.new(9_000) { |i| { date: "2026-01-01", amount: "1.00", name: "CHARGE #{i} AT A STORE WITH A LONG NAME" } }
      generation = Ai::Generations::SuggestBillSetup.new(charges:, categories: CATEGORIES)
      endpoint = Ai::Spike::Presets.llama_cpp(json_mode: "json_object")
      with_spike_cassette("llama_cpp/error_context_too_long_#{label.underscore}") do
        error = assert_raises(Ai::Error::ContextTooLong) { generation.call(route: llama_route(endpoint:), hand_written:) }
        assert_match(/context size/, error.message)
      end
    end

    test "#{label}: a refused port is Unreachable (live, loopback)" do
      endpoint = Ai::Spike::Presets.llama_cpp(base_url: "http://127.0.0.1:9/v1", json_mode: "json_object")
      assert_raises(Ai::Error::Unreachable) { bill_setup.call(route: llama_route(endpoint:), hand_written:) }
    end
  end

  test "a timeout shorter than a slow llama.cpp request is Timeout, with one attempt (live only)" do
    skip "live only: needs SPIKE_RECORD=1 and the llama.cpp server" unless recording?

    endpoint = Ai::Spike::Presets.llama_cpp(timeout_seconds: 2, json_mode: "none",
                                            extra_body: { chat_template_kwargs: { enable_thinking: true } })
    VCR.turned_off do
      WebMock.allow_net_connect!
      BOTH.each_value do |hand_written|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        assert_raises(Ai::Error::Timeout) { bill_setup.call(route: llama_route(endpoint:), hand_written:) }
        assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 6, "no retries: one 2s wait, not four"
      end
    ensure
      WebMock.disable_net_connect!
    end
  end

  # WebMock: retries and timeouts ------------------------------------------

  URL = "http://lmstudio.test/v1/chat/completions".freeze

  { 429 => Ai::Error::RateLimited, 500 => Ai::Error::Upstream, 503 => Ai::Error::Upstream }.each do |status, error|
    BOTH.each do |label, hand_written|
      test "#{label}: #{status} is #{error.name.demodulize} after one request with the endpoint's retries" do
        stub = stub_request(:post, URL).to_return(json_error(status, "status #{status}"))
        assert_raises(error) { bill_setup.call(route: stub_route(Ai::Spike::Presets.lmstudio(json_mode: "json_object")), hand_written:) }
        assert_requested stub, times: 1
      end
    end

    test "RubyLLM's own defaults send #{status} four times" do
      stub = stub_request(:post, URL).to_return(json_error(status, "status #{status}"))
      context = RubyLLM.context { |c| c.openai_api_key = "x"; c.openai_api_base = "http://lmstudio.test/v1"; c.retry_interval = 0.01 }
      assert_raises(RubyLLM::Error) { context.chat(model: "m", provider: :openai, protocol: :chat_completions, assume_model_exists: true).ask("hi") }
      assert_requested stub, times: 4
    end
  end

  BOTH.each do |label, hand_written|
    test "#{label}: a connect timeout is Unreachable (Faraday reports Net::OpenTimeout as ConnectionFailed)" do
      stub_request(:post, URL).to_timeout
      assert_raises(Ai::Error::Unreachable) { bill_setup.call(route: stub_route(Ai::Spike::Presets.lmstudio(json_mode: "json_object")), hand_written:) }
    end
  end

  test "a read timeout is one request with the endpoint's settings and four with RubyLLM's defaults" do
    stub = stub_request(:post, URL).to_raise(Net::ReadTimeout)
    BOTH.each_value do |hand_written|
      assert_raises(Ai::Error::Timeout) { bill_setup.call(route: stub_route(Ai::Spike::Presets.lmstudio(json_mode: "json_object")), hand_written:) }
    end
    assert_requested stub, times: 2

    WebMock.reset_executed_requests!
    context = RubyLLM.context { |c| c.openai_api_key = "x"; c.openai_api_base = "http://lmstudio.test/v1"; c.retry_interval = 0.01 }
    assert_raises(Faraday::TimeoutError) { context.chat(model: "m", provider: :openai, protocol: :chat_completions, assume_model_exists: true).ask("hi") }
    assert_requested stub, times: 4
    assert_equal 300, RubyLLM.config.request_timeout, "each of the four waits up to 300s by default"
  end

  test "the endpoint's timeout and retries reach RubyLLM's connection" do
    transport = Ai::Transport::Compatible.new(Ai::Spike::Presets.llama_cpp(timeout_seconds: 7, max_retries: 0))
    config = transport.send(:ruby_llm_context).config
    assert_equal [ 7, 0 ], [ config.request_timeout, config.max_retries ]
  end

  # WebMock: each provider's context-length wording -------------------------

  {
    "OpenAI / OpenRouter" => [ :openrouter, "This endpoint's maximum context length is 131072 tokens. However, you requested about 140000 tokens." ],
    "LM Studio" => [ :lmstudio, "The number of tokens to keep from the initial prompt is greater than the context length. Try to load the model with a larger context length, or provide a shorter input" ],
    "llama.cpp" => [ :llama_cpp, "the request exceeds the available context size, try increasing it" ]
  }.each do |provider, (preset, wording)|
    BOTH.each do |label, hand_written|
      test "#{label}: #{provider}'s context-length 400 is ContextTooLong" do
        endpoint = Ai::Spike::Presets.public_send(preset, api_key: "k", json_mode: "json_object")
        stub_request(:post, "#{Ai::Transport::Http.compatible_base(endpoint.base_url)}/chat/completions")
          .to_return(json_error(400, wording, "invalid_request_error"))
        assert_raises(Ai::Error::ContextTooLong) { bill_setup.call(route: stub_route(endpoint), hand_written:) }
      end
    end
  end

  {
    [ 400, "invalid_request_error", "prompt is too long: 212000 tokens > 200000 maximum" ] => Ai::Error::ContextTooLong,
    [ 401, "authentication_error", "invalid x-api-key" ] => Ai::Error::Unauthorized,
    [ 429, "rate_limit_error", "Number of request tokens has exceeded your per-minute rate limit" ] => Ai::Error::RateLimited,
    [ 529, "overloaded_error", "Overloaded" ] => Ai::Error::Upstream,
    [ 400, "invalid_request_error", "tool_choice: forced tool use is not supported with this model" ] => Ai::Error::Refused
  }.each do |(status, type, message), error|
    BOTH.each do |label, hand_written|
      test "#{label}: Anthropic #{status} #{type} is #{error.name.demodulize}" do
        stub = stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(anthropic_error(status, message, type))
        route = stub_route(Ai::Spike::Presets.anthropic(api_key: "sk-ant"), name: "claude-haiku-4-5")
        assert_raises(error) { bill_setup.call(route:, hand_written:) }
        assert_requested stub, times: 1
      end
    end
  end

  test "an error event carries the error class" do
    stub_request(:post, URL).to_return(json_error(429, "slow down"))
    events = capture_ai_events do
      assert_raises(Ai::Error::RateLimited) { bill_setup.call(route: stub_route(Ai::Spike::Presets.lmstudio(json_mode: "json_object"))) }
    end
    assert_equal "Ai::Error::RateLimited", events.sole.payload[:error]
  end
end
