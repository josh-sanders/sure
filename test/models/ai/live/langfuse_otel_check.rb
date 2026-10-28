# Live Langfuse check (not a test) of metadata tracing: RubyLLM's own
# OpenTelemetry spans, without Sure's subscriber. With the spike ENV and
# LANGFUSE_* loaded,
#   bin/rails runner test/models/ai/live/langfuse_otel_check.rb
# points the standard OTEL_EXPORTER_OTLP_* variables at Langfuse, starts the
# "metadata" mode, runs one generate and one two-round chat turn on llama.cpp
# under one correlation id, then reads back what Langfuse stored.
host, auth = ENV.fetch("LANGFUSE_HOST"), [ ENV.fetch("LANGFUSE_PUBLIC_KEY"), ENV.fetch("LANGFUSE_SECRET_KEY") ]
ENV["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] = "#{host.chomp('/')}/api/public/otel/v1/traces"
ENV["OTEL_EXPORTER_OTLP_TRACES_HEADERS"] =
  "Authorization=#{URI.encode_uri_component("Basic #{Base64.strict_encode64(auth.join(':'))}")},x-langfuse-ingestion-version=4"
provider = Ai::Instrumentation.start_tracing("metadata")

session = "spike-ruby-llm-metadata-#{Time.now.to_i}"
model = Ai::Spike::Model.new(endpoint: Ai::Spike::Presets.llama_cpp, name: "qwen3.6-35b-a3b-mtp", max_output_tokens: 2048)
route = Ai::Spike::Route.new(model:)
charges = (1..6).map { |i| { date: (Date.new(2026, 4, 15) + i.months).iso8601, amount: "15.49", name: "NETFLIX.COM AUTOPAY" } }
Ai::Correlation.with(session) do
  Ai::Generations::SuggestBillSetup.new(charges:, categories: %w[Entertainment Utilities]).call(route:)
  user = User.where.not(family_id: nil).first || raise("no user in this database")
  Ai::Conversation.new(route:, functions: [ Assistant::Function::GetAccounts.new(user) ], max_tool_rounds: 4, turn_timeout: 600,
                       instructions: "You are a finance assistant. Use tools. Be brief.")
                  .respond([ Ai::Transport::Base::Message.new(role: :user, content: "How many accounts do I have? Look them up.") ])
end
provider.force_flush(timeout: 30)

get = ->(path) {
  uri = URI("#{host}/api/public/#{path}")
  req = Net::HTTP::Get.new(uri).tap { _1.basic_auth(*auth) }
  JSON.parse(Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { _1.request(req) }.body)
}
observations = []
12.times do
  observations = get.("v2/observations?limit=100&fields=core,basic,io,usage,model")["data"].to_a.select { _1["sessionId"] == session }
  break if observations.size >= 3

  sleep 5
end
puts "session #{session}: #{observations.size} observations"
observations.sort_by { _1["startTime"] }.each do |o|
  puts format("  %-11s %-28s model=%-22s input=%-5s output=%-5s usage=%s", o["type"], o["name"], o["model"].inspect,
              o["input"].present?, o["output"].present?, o["usageDetails"].to_json)
end
