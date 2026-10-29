# Live Jev fan-out check (not a test), against OpenCode Zen's free Jev:
#   bin/rails runner test/models/ai/live/jev_fanout_check.rb
# Times one batch of transactions categorized by the hand-written provider
# and the gem-backed one at several concurrencies, with a new connection per
# request (both providers' default) and with a kept-alive one per thread,
# then the same batch packed into fewer requests: several transactions in
# one state, one choice question each.
ENDPOINT = "https://opencode.ai/zen/v1/systemone"
MODEL = "jev-1.13-free"
CATEGORIES = %w[Entertainment Utilities Groceries Transport Dining Health].each_with_index.map { |name, i| { id: "c#{i}", name:, parent_id: nil } }
TRUTH = {
  "NETFLIX.COM AUTOPAY" => "Entertainment", "SPOTIFY USA" => "Entertainment", "AMC THEATRES #2231" => "Entertainment",
  "PG&E WEB ONLINE PAYMENT" => "Utilities", "COMCAST XFINITY" => "Utilities", "CITY WATER DEPT AUTOPAY" => "Utilities",
  "WHOLE FOODS MARKET #10233" => "Groceries", "TRADER JOE'S #552" => "Groceries", "SAFEWAY STORE 1711" => "Groceries",
  "UBER *TRIP HELP.UBER.COM" => "Transport", "SHELL OIL 57444" => "Transport", "BART CLIPPER RELOAD" => "Transport",
  "CHIPOTLE 2291" => "Dining", "SQ *BLUE BOTTLE COFFEE" => "Dining",
  "CVS/PHARMACY #9921" => "Health", "KAISER PERMANENTE COPAY" => "Health"
}.freeze
TRANSACTIONS = TRUTH.keys.each_with_index.map { |description, i| { id: "t#{i + 1}", description:, amount: "25.00", classification: "expense" } }

# A kept-alive Net::HTTP per thread: Sure's pool threads each reuse theirs.
PERSISTENT = lambda do |url:, headers:, body:|
  uri = URI(url)
  http = (Thread.current[:jev_http] ||= Net::HTTP.new(uri.host, uri.port).tap { _1.use_ssl = true; _1.keep_alive_timeout = 30; _1.start })
  response = http.post(uri.request_uri, body, headers)
  [ response.code.to_i, response.body, response.each_header.to_h ]
end

def timed
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = yield
  [ result, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started ]
end

def report(label, seconds, picks, requests:, tokens: nil)
  right = picks.count { |id, category| TRUTH[TRANSACTIONS.find { _1[:id] == id }[:description]] == category }
  puts format("  %-50s %6.2fs  %2d requests  %2d/%d right%s", label, seconds, requests, right, TRANSACTIONS.size, tokens ? "  #{tokens} input tokens" : "")
end

def categorize(provider)
  response, seconds = timed { provider.auto_categorize(transactions: TRANSACTIONS, user_categories: CATEGORIES) }
  raise response.error unless response.success?

  [ response.data.to_h { [ _1.transaction_id, _1.category_name ] }, seconds, response.data.sum { _1.usage["input_tokens"].to_i } ]
end

puts "== One request per transaction (#{TRANSACTIONS.size} transactions)"
{ "hand-written" => ->(c) { Provider::Jev.new("public", endpoint: ENDPOINT, model: MODEL, concurrency: c) },
  "gem, new connection per request" => ->(c) { Provider::JevGem.new("public", endpoint: ENDPOINT, model: MODEL, concurrency: c) },
  "gem, kept-alive connection per thread" => ->(c) { Provider::JevGem.new("public", endpoint: ENDPOINT, model: MODEL, concurrency: c, transport: PERSISTENT) } }
  .each do |name, build|
    [ 1, 4, 8, 16 ].each do |concurrency|
      picks, seconds, tokens = categorize(build.(concurrency))
      report("#{name}, concurrency #{concurrency}", seconds, picks, requests: TRANSACTIONS.size, tokens:)
    end
  end

puts "== Packed: several transactions in one state, one choice question each (gem, kept-alive)"
provider = Provider::JevGem.new("public", endpoint: ENDPOINT, model: MODEL, transport: PERSISTENT)
criteria = CATEGORIES.to_h { [ _1[:name], nil ] }.merge(Provider::Jev::UNCATEGORIZED => "No listed category is a reasonable fit")
[ 4, 8, 16 ].each do |per_request|
  slices = TRANSACTIONS.each_slice(per_request).to_a
  results, seconds = timed do
    slices.map do |slice|
      Thread.new do
        provider.decide(
          state: slice.to_h { [ _1[:id], _1.except(:id) ] },
          questions: slice.to_h { |t| [ t[:id], { type: "choice", instructions: "Which spending category best fits bank transaction #{t[:id]} in the state?", criteria: } ] }
        )
      end
    end.map(&:value)
  end
  failed = results.reject(&:success?)
  raise failed.first.error if failed.any?

  picks = results.flat_map { |r| r.data.decisions.map { |key, decision| [ key, decision.value ] } }.to_h
  report("#{per_request} per request, #{slices.size} requests in parallel", seconds, picks, requests: slices.size, tokens: results.sum { _1.data.usage["input_tokens"].to_i })
end
