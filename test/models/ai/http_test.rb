require_relative "spike_helper"

class Ai::HttpTest < ActiveSupport::TestCase
  test "HTTPS_PROXY wins, HTTP_PROXY is the fallback, NO_PROXY bypasses by host or suffix" do
    http = Ai::Transport::Http
    assert_equal "http://a:1", http.proxy_for("http://llama:8080/v1", env: { "HTTPS_PROXY" => "http://a:1", "HTTP_PROXY" => "http://b:2" })
    assert_equal "http://b:2", http.proxy_for("https://api.anthropic.com", env: { "HTTP_PROXY" => "http://b:2" })
    assert_nil http.proxy_for("http://llama:8080/v1", env: { "HTTPS_PROXY" => "http://a:1", "NO_PROXY" => "llama,.internal" })
    assert_nil http.proxy_for("http://gpu.internal/v1", env: { "HTTPS_PROXY" => "http://a:1", "NO_PROXY" => "llama,.internal" })
    assert_equal "http://a:1", http.proxy_for("https://openrouter.ai/api/v1", env: { "HTTPS_PROXY" => "http://a:1", "NO_PROXY" => "llama" })
    assert_nil http.proxy_for("https://api.anthropic.com", env: {})
  end

  test "one normaliser for /v1" do
    %w[http://h:1 http://h:1/ http://h:1/v1 http://h:1/v1/].each do |url|
      assert_equal "http://h:1/v1", Ai::Transport::Http.compatible_base(url)
    end
    assert_equal "https://openrouter.ai/api/v1", Ai::Transport::Http.compatible_base("https://openrouter.ai/api")
  end

  test "every RubyLLM transport hands the resolved proxy to its context" do
    ClimateControl.modify(HTTPS_PROXY: "http://proxy:3128", NO_PROXY: "llama-cpp.test") do
      { Ai::Spike::Presets.anthropic(api_key: "k") => "http://proxy:3128",
        Ai::Spike::Presets.openrouter(api_key: "k") => "http://proxy:3128",
        Ai::Spike::Presets.llama_cpp => nil }.each do |endpoint, proxy|
        context = Ai::Transport.for(endpoint).send(:ruby_llm_context)
        proxy ? assert_equal(proxy, context.config.http_proxy, endpoint.name) : assert_nil(context.config.http_proxy, endpoint.name)
      end
    end
  end
end
