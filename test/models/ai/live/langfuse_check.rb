# Live Langfuse check (not a test): with the spike ENV and LANGFUSE_* loaded,
#   bin/rails runner test/models/ai/live/langfuse_check.rb
# runs one generate and one two-round chat turn on llama.cpp under one
# correlation id, flushes, then reads the traces back from Langfuse's API.
session = "spike-ruby-llm-#{Time.now.to_i}"
ActiveSupport::Notifications.subscribe(/\.ai\z/, Ai::Instrumentation::LangfuseSubscriber.new(environment: "spike"))

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
Rails.configuration.x.langfuse.flush

host, auth = ENV.fetch("LANGFUSE_HOST"), [ ENV.fetch("LANGFUSE_PUBLIC_KEY"), ENV.fetch("LANGFUSE_SECRET_KEY") ]
get = ->(path) {
  uri = URI("#{host}/api/public/#{path}")
  req = Net::HTTP::Get.new(uri).tap { _1.basic_auth(*auth) }
  JSON.parse(Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { _1.request(req) }.body)
}
# Langfuse v4 in events_only mode: /traces and /observations are gone; the
# v2 observations API is the read path.
observations = []
12.times do
  observations = get.("v2/observations?limit=50&fields=core,basic,io,usage")["data"].to_a.select { _1["sessionId"] == session }
  break if observations.count { _1["type"] == "GENERATION" } >= 3

  sleep 5
end
generations = observations.select { _1["type"] == "GENERATION" }.sort_by { _1["startTime"] }
puts "session #{session}: #{generations.size} generations"
generations.each do |o|
  input = JSON.parse(o["input"].to_s) rescue {}
  puts format("  %-12s round=%-4s messages=%-22s output=%-5s usage=%s", o["name"], input.dig("metadata", "round") || "-",
              Array(input["messages"]).map { _1["role"] }.join(">"), o["output"].present?, o["usageDetails"].to_json)
end
