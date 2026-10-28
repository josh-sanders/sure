# Builds every client's HTTP settings in one place (section 7): the endpoint's
# timeout and headers, and the proxy, resolved once from HTTPS_PROXY, then
# HTTP_PROXY, honouring NO_PROXY.
module Ai::Transport::Http
  module_function

  def proxy_for(base_url, env: ENV)
    proxy = env["HTTPS_PROXY"].presence || env["https_proxy"].presence ||
            env["HTTP_PROXY"].presence || env["http_proxy"].presence
    return if proxy.nil?

    uri = URI(base_url)
    no_proxy = env["NO_PROXY"].presence || env["no_proxy"].presence
    return if no_proxy && !URI::Generic.use_proxy?(uri.host, uri.host, uri.port, no_proxy)

    proxy
  end

  # One normaliser for every compatible server: with or without /v1, with or
  # without a trailing slash, the result ends in exactly one /v1.
  def compatible_base(base_url)
    url = base_url.to_s.strip.chomp("/")
    url.end_with?("/v1") ? url : "#{url}/v1"
  end

  def headers(endpoint) = endpoint.extra_headers.to_h

  # ruby-openai and the anthropic gem each take their own options; RubyLLM
  # takes a config. All three read from here.
  def faraday(endpoint)
    proxy = proxy_for(endpoint.base_url)
    ->(f) { f.proxy = proxy if proxy }
  end
end
