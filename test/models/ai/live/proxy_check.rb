# Live proxy check (not a test): run test/models/ai/live/forward_proxy.py 18899 <log>,
# then bin/rails runner test/models/ai/live/proxy_check.rb <log> with the spike ENV loaded.
LOG = ARGV.fetch(0)
PROXY = "http://127.0.0.1:18899"
charges = (1..3).map { |i| { date: "2026-0#{i}-15", amount: "15.49", name: "NETFLIX" } }
gen = Ai::Generations::SuggestBillSetup.new(charges:, categories: %w[Entertainment])
llama = Ai::Spike::Presets.llama_cpp(json_mode: "json_object")
route = ->(endpoint, name) { Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint:, name:, max_output_tokens: 300)) }

def through_proxy
  before = File.exist?(LOG) ? File.readlines(LOG).size : 0
  outcome = begin
    yield
    "ok"
  rescue Ai::Error::Base => e
    e.class.name.demodulize
  end
  lines = File.exist?(LOG) ? File.readlines(LOG).drop(before).map(&:strip) : []
  [ outcome, lines.map { _1.sub(%r{//10\.72\.200\.\d+:\d+}, "//llama-cpp") }.uniq ]
end

scenarios = {
  "HTTPS_PROXY only" => { "HTTPS_PROXY" => PROXY },
  "HTTP_PROXY only" => { "HTTP_PROXY" => PROXY },
  "HTTPS_PROXY + NO_PROXY=llama host" => { "HTTPS_PROXY" => PROXY, "NO_PROXY" => URI(llama.base_url).host }
}
calls = {
  "Compatible ruby_llm (llama.cpp, http)" => -> { gen.call(route: route.(llama, "qwen3.6-35b-a3b-mtp")) },
  "Compatible hand-written (llama.cpp, http)" => -> { gen.call(route: route.(llama, "qwen3.6-35b-a3b-mtp"), hand_written: true) },
  "embed ruby_llm (llama.cpp :8181)" => -> { Ai::Transport::Compatible.new(Ai::Spike::Presets.llama_cpp_embed).embed([ "hi" ], model: Ai::Spike::Model.new(endpoint: nil, name: "granite-embedding-small-english-r2")) },
  "Anthropic ruby_llm (bogus key, https)" => -> { gen.call(route: route.(Ai::Spike::Presets.anthropic(api_key: "sk-ant-bogus"), "claude-haiku-4-5")) },
  "Anthropic hand-written (bogus key, https)" => -> { gen.call(route: route.(Ai::Spike::Presets.anthropic(api_key: "sk-ant-bogus"), "claude-haiku-4-5"), hand_written: true) },
  "OpenRouter ruby_llm (bogus key, https)" => -> { gen.call(route: route.(Ai::Spike::Presets.openrouter(api_key: "sk-or-bogus"), "google/gemini-3-flash")) }
}
proxy_keys = %w[HTTPS_PROXY https_proxy HTTP_PROXY http_proxy NO_PROXY no_proxy]
scenarios.each do |scenario, env|
  puts "== #{scenario}"
  proxy_keys.each { ENV.delete(_1) }
  env.each { |k, v| ENV[k] = v }
  calls.each do |name, call|
    outcome, lines = through_proxy(&call)
    puts format("  %-44s %-13s proxy saw: %s", name, outcome, lines.empty? ? "nothing (direct)" : lines.join(", "))
  end
end
