# Live proxy check on one local container (not a test). Start the container and
# test/models/ai/live/forward_proxy.py 18899 <log>, then, with the spike ENV loaded:
#   bin/rails runner test/models/ai/live/container_proxy_check.rb <log> ollama|lmstudio|openclaw [scenario,...]
# Each call runs against the server's loopback address and against localhost.
LOG = ARGV.fetch(0)
SERVER = ARGV.fetch(1).to_sym
PROXY = "http://127.0.0.1:18899"
T = Ai::Transport::Base

charges = (1..3).map { |i| { date: "2026-0#{i}-15", amount: "15.49", name: "NETFLIX" } }
gen = Ai::Generations::SuggestBillSetup.new(charges:, categories: %w[Entertainment])
route = ->(endpoint, name) { Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint:, name:, max_output_tokens: 300)) }
ask = ->(text) { [ T::Message.new(role: :user, content: text) ] }

def through_proxy
  before = File.exist?(LOG) ? File.readlines(LOG).size : 0
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  outcome = begin
    yield
  rescue StandardError => e
    "#{e.class.name.demodulize}: #{e.message}"
  end
  lines = File.exist?(LOG) ? File.readlines(LOG).drop(before).map(&:strip) : []
  [ outcome, lines.uniq, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started ]
end

# Streams a short answer and reports how many chunks arrived, and how long
# after the first chunk the last one came, to show the proxy doesn't buffer.
def streamed(chunks_at)
  first, last = chunks_at.minmax
  "ok, #{chunks_at.size} chunks over #{(last - first).round(1)}s"
end

def stream_converse(endpoint, model)
  chunks_at = []
  request = T::ConverseRequest.new(model: Ai::Spike::Model.new(endpoint:, name: model), instructions: nil,
                                   messages: [ T::Message.new(role: :user, content: "Count from one to twenty in words, comma-separated.") ],
                                   max_tokens: 200, metadata: { feature: :chat, end_user: "proxy-check" })
  Ai::Transport::Compatible.new(endpoint).converse(request) { chunks_at << Process.clock_gettime(Process::CLOCK_MONOTONIC) }
  streamed(chunks_at)
end

def at(url, host) = url.sub("127.0.0.1", host)

calls = ->(host) do
  case SERVER
  when :ollama, :lmstudio
    endpoint = Ai::Spike::Presets.public_send(SERVER, base_url: at(Ai::Spike::Presets.public_send(SERVER).base_url, host), json_mode: "strict")
    model = "qwen3-30b-a3b-instruct"
    list = {
      "generate ruby_llm" => -> { gen.call(route: route.(endpoint, model)) && "ok" },
      "generate hand-written" => -> { gen.call(route: route.(endpoint, model), hand_written: true) && "ok" },
      "converse ruby_llm, streamed" => -> { stream_converse(endpoint, model) }
    }
    list["embed ruby_llm"] = -> { Ai::Transport::Compatible.new(endpoint).embed([ "hi" ], model: Ai::Spike::Model.new(endpoint:, name: "granite-embedding-small-english-r2")) && "ok" } if SERVER == :ollama
    list
  when :openclaw
    endpoint = Ai::Spike::Presets.openclaw(base_url: at(Ai::Spike::Presets.openclaw.base_url, host))
    {
      "agent converse ruby_llm, streamed" => -> { stream_converse(endpoint, "openclaw") },
      "agent on main (External::Client), streamed" => lambda {
        chunks_at = []
        Assistant::External::Client.new(url: endpoint.base_url, token: endpoint.api_key)
          .chat(messages: [ { role: "user", content: "Count from one to twenty in words, comma-separated." } ], user: "proxy-check") { chunks_at << Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        streamed(chunks_at)
      }
    }
  end
end

scenarios = {
  "no proxy" => {},
  "HTTPS_PROXY only" => { "HTTPS_PROXY" => PROXY },
  "HTTP_PROXY only" => { "HTTP_PROXY" => PROXY },
  "HTTPS_PROXY + NO_PROXY=127.0.0.1" => { "HTTPS_PROXY" => PROXY, "NO_PROXY" => "127.0.0.1" },
  "HTTPS_PROXY + NO_PROXY=localhost" => { "HTTPS_PROXY" => PROXY, "NO_PROXY" => "localhost" },
  "HTTPS_PROXY + NO_PROXY=127.0.0.0/8" => { "HTTPS_PROXY" => PROXY, "NO_PROXY" => "127.0.0.0/8" },
  # main's External::Client reads only the scheme's own proxy variable.
  "HTTP_PROXY + NO_PROXY=127.0.0.0/8" => { "HTTP_PROXY" => PROXY, "NO_PROXY" => "127.0.0.0/8" }
}
scenarios = scenarios.slice(*ARGV[2].split(",")) if ARGV[2]
proxy_keys = %w[HTTPS_PROXY https_proxy HTTP_PROXY http_proxy NO_PROXY no_proxy]
scenarios.each do |scenario, env|
  puts "== #{scenario}"
  proxy_keys.each { ENV.delete(_1) }
  env.each { |k, v| ENV[k] = v }
  %w[127.0.0.1 localhost].each do |host|
    calls.(host).each do |name, call|
      outcome, lines, seconds = through_proxy(&call)
      seen = lines.empty? ? "nothing (direct)" : lines.join(", ")
      puts format("  %-10s %-44s %-34s %5.1fs  proxy saw: %s", host, name, outcome.to_s[0, 160], seconds, seen)
    end
  end
end
