require "test_helper"

# Live runs record cassettes under test/vcr_cassettes/ai/<preset>/ when
# SPIKE_RECORD=1 and the spike's ENV is loaded; otherwise tests replay.
# Keys are filtered, and each server's real address is swapped for the
# placeholder URL Ai::Spike::Presets falls back to without ENV.
VCR.configure do |config|
  %w[SPIKE_LLAMA_CPP_API_KEY SPIKE_ANTHROPIC_API_KEY SPIKE_OPENROUTER_API_KEY SPIKE_GEMINI_API_KEY SPIKE_OPENCLAW_TOKEN LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY].each do |key|
    config.filter_sensitive_data("<#{key}>") { ENV[key].presence }
  end
  {
    "SPIKE_LLAMA_CPP_URL" => :llama_cpp, "SPIKE_LLAMA_CPP_EMBED_URL" => :llama_cpp_embed,
    "SPIKE_OLLAMA_URL" => :ollama, "SPIKE_LMSTUDIO_URL" => :lmstudio, "SPIKE_OPENCLAW_URL" => :openclaw
  }.each do |env, key|
    config.filter_sensitive_data(Ai::Spike::Presets::PLACEHOLDERS[key]) { ENV[env].presence&.chomp("/") }
  end
end

module AiSpikeHelper
  LLAMA_MODEL = "qwen3.6-35b-a3b-mtp".freeze

  CHARGES = (1..6).map { |i| { date: (Date.new(2026, 4, 15) + i.months).iso8601, amount: "15.49", name: "NETFLIX.COM AUTOPAY" } }.freeze
  CATEGORIES = %w[Entertainment Utilities Groceries].freeze
  NETFLIX_JSON = { name: "Netflix", amount: 15.49, frequency: "monthly", day_of_month: 15, weekday: nil, month_of_year: nil,
                   category_name: "Entertainment", bill_type: "subscription", autopay: true, confidence: 0.9, rationale: "Monthly." }.to_json.freeze

  def recording? = ENV["SPIKE_RECORD"] == "1"

  # Recording starts from an empty cassette: VCR's :all keeps old interactions
  # beside the new ones, and these share one URI, so replay would pick stale ones.
  # Sure's VCR setup ignores localhost, where the spike's containers listen, so
  # localhost is recorded only inside this block.
  # Parallel requests to one URI arrive in any order, so they match on the body too.
  def with_spike_cassette(name, match: %i[method uri], &)
    FileUtils.rm_f(Rails.root.join("test/vcr_cassettes/ai/#{name}.yml")) if recording?
    VCR.configuration.ignore_localhost = false
    VCR.use_cassette("ai/#{name}", record: recording? ? :all : :none, match_requests_on: match, &)
  ensure
    VCR.configuration.ignore_localhost = true
  end

  def bill_setup = Ai::Generations::SuggestBillSetup.new(charges: CHARGES, categories: CATEGORIES)

  def llama_route(endpoint: Ai::Spike::Presets.llama_cpp, **route)
    Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint:, name: LLAMA_MODEL, max_output_tokens: 4096), **route)
  end

  def capture_ai_events
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(/\.ai\z/) { |event| events << event }
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def assert_netflix(value)
    assert_equal 15.49, value[:amount]
    assert_equal "monthly", value[:frequency]
    assert_equal 15, value[:day_of_month]
    assert_equal "Entertainment", value[:category_name]
    assert_equal "subscription", value[:bill_type]
  end

  def request_bodies(path_pattern)
    WebMock::RequestRegistry.instance.requested_signatures.hash.keys
      .select { _1.uri.to_s.match?(path_pattern) }
      .map { JSON.parse(_1.body) }
  end
end
