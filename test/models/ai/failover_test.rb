require_relative "spike_helper"

# Spike for decision 12 (routes): section 5.4's failover against a gateway,
# one endpoint and key in front of many models (OpenRouter, Vercel AI
# Gateway, Bedrock), and a local server, under Ai::Spike::Failover's three
# marking rules. Then, for contrast, RubyLLM's with_fallbacks inside one
# entry: what Sure's router, events and usage see. WebMock only.
class Ai::FailoverTest < ActiveSupport::TestCase
  include AiSpikeHelper

  GATEWAY = "https://gateway.test/v1/chat/completions".freeze
  LOCAL = "http://llama.test/v1/chat/completions".freeze

  # Spike knob: RubyLLM fallbacks on every chat the compatible transport builds.
  module RubyLlmFallbacks
    singleton_class.attr_accessor :models, :seen

    private
      def ruby_llm_chat(...)
        chat = super
        return chat unless RubyLlmFallbacks.models

        chat.with_fallbacks(*RubyLlmFallbacks.models)
        chat.after_fallback { RubyLlmFallbacks.seen << _1 }
        chat
      end
  end
  Ai::Transport::Compatible.prepend(RubyLlmFallbacks)

  setup do
    gateway = Ai::Spike::Endpoint.new(name: "gateway", protocol: :compatible, preset: :gateway, base_url: "https://gateway.test/v1",
                                      api_key: "gw-key", json_mode: "strict", timeout_seconds: 30)
    local = Ai::Spike::Endpoint.new(name: "llama", protocol: :compatible, preset: :llama_cpp, base_url: "http://llama.test/v1",
                                    api_key: nil, json_mode: "strict", timeout_seconds: 30)
    @gw_a, @gw_b = route(gateway, "vendor-a/model-a"), route(gateway, "vendor-b/model-b")
    @local_small, @local_big = route(local, "qwen3-3b"), route(local, "gpt-oss-20b")
    RubyLlmFallbacks.models = nil
    RubyLlmFallbacks.seen = []
  end

  teardown { RubyLlmFallbacks.models = nil }

  # --- a gateway: one model fails, the others on the same key are fine ---

  test "a 503 for one gateway model" do
    gateway_answers("vendor-a/model-a", error(503, "Provider returned error"))
    gateway_answers("vendor-b/model-b", completion)
    local_answers(completion)

    outcomes = each_rule { |failover| [ failover.run(routes) { call(_1) }, run_or_reason(failover, [ @gw_b ]) ] }

    # The plan marks the gateway down: model-b is skipped now and for 60 s,
    # by every feature, and the call leaves for the next server.
    assert_equal [ "llama/qwen3-3b", "all_routes_down" ], summary(outcomes[:plan])
    # Marking the model keeps the rest of the gateway in use.
    assert_equal [ "gateway/vendor-b/model-b", "gateway/vendor-b/model-b" ], summary(outcomes[:response])
    assert_equal [ "gateway/vendor-b/model-b", "gateway/vendor-b/model-b" ], summary(outcomes[:location])
    assert_equal %i[server model model], outcomes.values.map { _1.first.attempts.first.mark }
  end

  test "a 429 for one gateway model (an upstream's rate limit, not the key's)" do
    gateway_answers("vendor-a/model-a", error(429, "Rate limit exceeded: upstream"))
    gateway_answers("vendor-b/model-b", completion)
    local_answers(completion)

    outcomes = each_rule { |failover| [ failover.run(routes) { call(_1) }, run_or_reason(failover, [ @gw_b ]) ] }

    assert_equal [ "llama/qwen3-3b", "all_routes_down" ], summary(outcomes[:plan])
    assert_equal [ "gateway/vendor-b/model-b", "gateway/vendor-b/model-b" ], summary(outcomes[:response])
    assert_equal [ "gateway/vendor-b/model-b", "gateway/vendor-b/model-b" ], summary(outcomes[:location])
    assert_equal %i[key model model], outcomes.values.map { _1.first.attempts.first.mark }
  end

  test "a 429 for the whole key: marking the model costs a call, and at most once loses the answer" do
    gateway_answers("vendor-a/model-a", error(429, "Rate limit exceeded"))
    gateway_answers("vendor-b/model-b", error(429, "Rate limit exceeded"))
    local_answers(completion)

    outcomes = each_rule { |failover| run_or_reason(failover, routes) }

    assert_equal "llama/qwen3-3b", outcomes[:plan]
    assert_equal "RateLimited", outcomes[:response], "model-a, then model-b, and the one move is spent"
    assert_equal "RateLimited", outcomes[:location]
    assert_equal "llama/qwen3-3b", run_or_reason(Ai::Spike::Failover.new(rule: :location, max_moves: 2), routes)
    assert_equal 1 + 2 + 2 + 2, gateway_requests
  end

  test "a 401 marks the key under every rule" do
    gateway_answers("vendor-a/model-a", error(401, "Invalid API key"))
    gateway_answers("vendor-b/model-b", error(401, "Invalid API key"))
    local_answers(completion)

    outcomes = each_rule { |failover| [ failover.run(routes) { call(_1) }, run_or_reason(failover, [ @gw_b ]) ] }

    outcomes.each_value { assert_equal [ "llama/qwen3-3b", "all_routes_down" ], summary(_1) }
    assert_equal 3, gateway_requests, "one per rule: model-b is never tried"
  end

  # --- a local server: when it fails, all of it fails ---

  test "a refused connection marks the server under every rule" do
    stub_request(:post, LOCAL).to_raise(Errno::ECONNREFUSED)
    gateway_answers("vendor-a/model-a", completion)

    outcomes = each_rule { |failover| [ failover.run(local_first) { call(_1) }, run_or_reason(failover, [ @local_big ]) ] }

    outcomes.each_value { assert_equal [ "gateway/vendor-a/model-a", "all_routes_down" ], summary(_1) }
    assert_equal 3, local_requests, "one per rule: the second local model is never tried"
  end

  test "a read timeout on a hung local server: marking only the model tries the next model on it" do
    stub_request(:post, LOCAL).to_raise(Net::ReadTimeout)
    gateway_answers("vendor-a/model-a", completion)

    outcomes = each_rule { |failover| run_or_reason(failover, local_first) }

    assert_equal "gateway/vendor-a/model-a", outcomes[:plan]
    assert_equal "Timeout", outcomes[:response], "qwen3-3b, then gpt-oss-20b on the same hung server"
    assert_equal "gateway/vendor-a/model-a", outcomes[:location]
    assert_equal 1 + 2 + 1, local_requests
  end

  test "escalation stays on the same server under every rule, and marks nothing" do
    stub_request(:post, LOCAL).with(body: hash_including("model" => "qwen3-3b")).to_return(completion("not json at all"))
    stub_request(:post, LOCAL).with(body: hash_including("model" => "gpt-oss-20b")).to_return(completion)

    outcomes = each_rule { |failover| failover.run(local_first) { call(_1) } }

    outcomes.each_value do |outcome|
      assert_equal "llama/gpt-oss-20b", route_label(outcome.route)
      assert_equal [ [ "InvalidOutput", nil ] ], outcome.attempts.map { [ _1.error, _1.mark ] }
    end
  end

  # --- the owner's calls (1 Nov) ---

  test "location with no move limit: a four-entry list is tried in order, skipping what's down" do
    gateway_answers("vendor-a/model-a", error(429, "Rate limit exceeded"))
    gateway_answers("vendor-b/model-b", error(429, "Rate limit exceeded"))
    stub_request(:post, LOCAL).to_raise(Errno::ECONNREFUSED)
    other = route(Ai::Spike::Endpoint.new(name: "other", protocol: :compatible, preset: :gateway, base_url: "https://other.test/v1",
                                          api_key: "other-key", json_mode: "strict"), "vendor-c/model-c")
    stub_request(:post, "https://other.test/v1/chat/completions").to_return(completion)
    failover = Ai::Spike::Failover.new(rule: :location, max_moves: nil)

    outcome = failover.run([ @gw_a, @gw_b, @local_small, other ]) { call(_1) }

    assert_equal "other/vendor-c/model-c", route_label(outcome.route)
    assert_equal [ %w[RateLimited model], %w[RateLimited model], %w[Unreachable server] ], outcome.attempts.map { [ _1.error, _1.mark.to_s ] }
    # Next time the three marked entries are skipped without a call.
    assert_equal "other/vendor-c/model-c", run_or_reason(failover, [ @gw_a, @gw_b, @local_big, other ])
    assert_equal [ 2, 1 ], [ gateway_requests, local_requests ]
  end

  test "a family's own key fails over only to its own keys, never the operator's key or a local server" do
    own_a, own_b = @gw_a.with(family_key: true), @gw_b.with(family_key: true)
    gateway_answers("vendor-a/model-a", error(503, "Provider returned error"))
    gateway_answers("vendor-b/model-b", completion)
    local_answers(completion)
    failover = Ai::Spike::Failover.new(rule: :location, max_moves: nil)

    # One model fails: the family's other model on its own key answers.
    assert_equal "gateway/vendor-b/model-b", run_or_reason(failover, [ own_a, own_b, @local_small ])

    # Its key fails: the error stands for the family admin's notice, and
    # neither the local server nor the operator's key on another gateway is tried.
    WebMock.reset!
    gateway_answers("vendor-a/model-a", error(401, "Invalid API key"))
    local_answers(completion)
    failover = Ai::Spike::Failover.new(rule: :location, max_moves: nil)
    operators = route(Ai::Spike::Endpoint.new(name: "other", protocol: :compatible, preset: :gateway, base_url: "https://other.test/v1",
                                              api_key: "operator-key", json_mode: "strict"), "vendor-c/model-c")

    assert_equal "Unauthorized", run_or_reason(failover, [ own_a, own_b, @local_small, operators ])
    assert_equal [ 1, 0 ], [ gateway_requests, local_requests ]
  end

  # --- RubyLLM's fallbacks inside one entry, for contrast ---

  test "RubyLLM fallback by model ID: a model outside the registry replaces the 503 with ModelNotFound" do
    gateway_answers("vendor-a/model-a", error(503, "Provider returned error"))
    RubyLlmFallbacks.models = [ "vendor-b/model-b" ]

    # ModelNotFoundError isn't a RubyLLM::Error, so it passes the transport's
    # error mapping as RubyLLM's own class, and Sure's failover doesn't see it.
    error = assert_raises(RubyLLM::ModelNotFoundError) { Ai::Spike::Failover.new(rule: :response).run(routes) { call(_1) } }

    assert_match "vendor-b/model-b", error.message
    assert_equal 1, gateway_requests
  end

  test "RubyLLM fallback by Model object: model-b answers, and Sure sees model-a succeed" do
    gateway_answers("vendor-a/model-a", error(503, "Provider returned error"))
    gateway_answers("vendor-b/model-b", completion(NETFLIX_JSON, input: 900, output: 300))
    RubyLlmFallbacks.models = [ RubyLLM::Model.default("vendor-b/model-b", "openai") ]
    failover = Ai::Spike::Failover.new(rule: :response)

    outcome = nil
    events = capture_ai_events { outcome = failover.run(routes) { call(_1) } }

    assert_netflix outcome.result.value
    # Sure's router, its .ai event and the result all name model-a, with no
    # error: no down mark, nothing for the health page or the footer line.
    assert_equal "gateway/vendor-a/model-a", route_label(outcome.route)
    assert_empty outcome.attempts
    assert_not failover.down?(@gw_a)
    assert_equal [ [ "vendor-a/model-a", nil ] ], events.map { [ _1.payload[:model], _1.payload[:error] ] }
    # The usage is model-b's, recorded against model-a's price.
    assert_equal [ 900, 300 ], [ outcome.result.usage.input_tokens, outcome.result.usage.output_tokens ]
    # RubyLLM knows: one fallback, with the error that caused it.
    fallback = RubyLlmFallbacks.seen.sole
    assert_equal [ "vendor-a/model-a", "vendor-b/model-b", true ], [ fallback.from.id, fallback.to.id, fallback.succeeded? ]
    assert_kind_of RubyLLM::Error, fallback.error
    # model-b gets model-a's strict schema: the entry's settings carry over.
    assert_equal [ %w[vendor-a/model-a json_schema], %w[vendor-b/model-b json_schema] ],
                 request_bodies(%r{gateway.test}).map { [ _1["model"], _1.dig("response_format", "type") ] }
  end

  test "RubyLLM fallback: a 400 from model-b's strict schema is not a fallback error, and auto's chain restarts on model-a" do
    gateway_answers("vendor-a/model-a", error(503, "Provider returned error"))
    gateway_answers("vendor-b/model-b", error(400, "response_format json_schema is not supported by this model"))
    RubyLlmFallbacks.models = [ RubyLLM::Model.default("vendor-b/model-b", "openai") ]
    auto = route(@gw_a.endpoint, "vendor-a/model-a", json_mode: "auto")

    assert_raises(Ai::Error::Base) { call(auto) }

    # Sure's auto chain sees model-b's 400 and retries json_object, on a new
    # chat: model-a again, then model-b again.
    assert_equal %w[vendor-a/model-a:json_schema vendor-b/model-b:json_schema vendor-a/model-a:json_object vendor-b/model-b:json_object],
                 request_bodies(%r{gateway.test}).first(4).map { "#{_1['model']}:#{_1.dig('response_format', 'type')}" }
  end

  private
    def route(endpoint, name, **overrides)
      Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint:, name:, max_output_tokens: 2048), **overrides)
    end

    def routes = [ @gw_a, @gw_b, @local_small ]
    def local_first = [ @local_small, @local_big, @gw_a ]

    def call(route) = bill_setup.call(route:)

    def each_rule = Ai::Spike::Failover::RULES.index_with { yield Ai::Spike::Failover.new(rule: _1) }

    # The route that answered, or the error's short name (or the unavailable reason).
    def run_or_reason(failover, routes)
      route_label(failover.run(routes) { call(_1) }.route)
    rescue Ai::Error::Unavailable => e
      e.reason.to_s
    rescue Ai::Error::Base => e
      e.class.name.demodulize
    end

    def summary((outcome, second)) = [ route_label(outcome.route), second ]
    def route_label(route) = "#{route.endpoint.name}/#{route.model.name}"

    def gateway_answers(model, *responses)
      stub_request(:post, GATEWAY).with(body: hash_including("model" => model)).to_return(*responses)
    end

    def local_answers(*responses) = stub_request(:post, LOCAL).to_return(*responses)

    def gateway_requests = requests(GATEWAY)
    def local_requests = requests(LOCAL)

    def requests(url) = WebMock::RequestRegistry.instance.times_executed(WebMock::RequestPattern.new(:post, url))

    def completion(content = NETFLIX_JSON, input: 400, output: 100)
      { status: 200, headers: { "Content-Type" => "application/json" }, body: {
        id: "chatcmpl-1", object: "chat.completion", model: "m",
        choices: [ { index: 0, finish_reason: "stop", message: { role: "assistant", content: } } ],
        usage: { prompt_tokens: input, completion_tokens: output, total_tokens: input + output }
      }.to_json }
    end

    def error(status, message)
      { status:, headers: { "Content-Type" => "application/json" }, body: { error: { message:, code: status } }.to_json }
    end
end
