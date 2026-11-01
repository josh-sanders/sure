# Live check (not a test) against the spike's llama.cpp (one slot, MTP):
#   set -a; . ./.env.local; set +a; ruby test/models/ai/live/cache_prefill_check.rb
#
# A. Does a chat's prompt cache survive another call between its rounds?
#    Round 1 of a chat (~3.3k tokens), then optionally another call, then
#    round 2 (round 1's prompt plus its answer and a follow-up). llama.cpp's
#    own timings say how much of round 2's prompt it served from cache
#    (cache_n) and how much it read again (prompt_n).
# B. How long does a chat wait behind a call still reading its prompt?
#    A long background prompt starts; 10 s later a chat is sent. B1 leaves
#    the background call alone (llama.cpp queues the chat behind it). B2
#    closes the background call's connection when the chat is sent, to see
#    whether llama.cpp stops a prompt read on disconnect.
#
# Every prompt carries a nonce, so nothing is served from an earlier run.
require "net/http"
require "json"
require "uri"
require "securerandom"

BASE = ENV.fetch("SPIKE_LLAMA_CPP_URL").chomp("/")
KEY = ENV.fetch("SPIKE_LLAMA_CPP_API_KEY")
MODEL = "qwen3.6-35b-a3b-mtp"
T0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def now = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - T0).round(2)

DESCRIPTIONS = [ "NETFLIX.COM", "SPOTIFY USA", "WHOLE FOODS MARKET", "SHELL OIL", "UBER *TRIP", "AMAZON MKTPLACE",
                 "COMCAST XFINITY", "PG&E WEB PAYMENT", "CHIPOTLE", "CVS/PHARMACY", "ADOBE CREATIVE CLD", "GYM MEMBERSHIP" ].freeze

def chat_messages(nonce)
  history = 120.times.map { |i| "2026-#{format('%02d', 10 - (i / 31) % 9)}-#{format('%02d', 1 + i % 28)} #{DESCRIPTIONS[(i * 3) % DESCRIPTIONS.size]} -#{format('%.2f', 3 + (i * 7.31) % 140)}" }
  [ { role: "system", content: "Session #{nonce}. You are the assistant in a personal finance app. Answer from the transactions given, briefly." },
    { role: "user", content: "My recent transactions:\n#{history.join("\n")}\n\nWhich of these are subscriptions, and roughly what do they cost me each month?" } ]
end

def merchant_messages(nonce)
  rows = 25.times.map { |i| "t#{i + 1}: #{DESCRIPTIONS[(i * 5) % DESCRIPTIONS.size]} #{1000 + i * 37} #{format('%.2f', 4 + (i * 3.7) % 90)}" }
  [ { role: "system", content: "Run #{nonce}. For each transaction, name the business behind it and its website, or null when unsure. Answer as JSON: {\"merchants\":[{\"transaction_id\",\"business_name\",\"business_url\"}]}." },
    { role: "user", content: rows.join("\n") } ]
end

def statement_messages(nonce, lines: 260)
  rows = lines.times.map { |i| "#{format('%02d', 1 + i % 28)}/0#{1 + (i / 28) % 9}/2026  CARD PURCHASE #{DESCRIPTIONS[(i * 7) % DESCRIPTIONS.size]} REF #{100_000 + i * 13}   #{format('%.2f', 2 + (i * 11.3) % 400)}   #{format('%.2f', 5000 - i * 9.1)}" }
  [ { role: "system", content: "Job #{nonce}. Extract every transaction from this bank statement text as JSON." },
    { role: "user", content: "Statement text:\n#{rows.join("\n")}" } ]
end

# Streams one request. Returns a record with the send time, first content
# time, end time and llama.cpp's timings. on_start receives the Net::HTTP
# object so another thread can close its connection.
def call(messages, max_tokens:, label:, on_start: nil)
  uri = URI("#{BASE}/chat/completions")
  record = { label:, sent: now }
  body = { model: MODEL, messages:, max_tokens:, stream: true, stream_options: { include_usage: true }, temperature: 0.2 }
  Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", read_timeout: 900) do |http|
    on_start&.call(http)
    req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json", "Authorization" => "Bearer #{KEY}")
    req.body = body.to_json
    buffer = +""
    http.request(req) do |res|
      record[:status] = res.code.to_i
      res.read_body do |chunk|
        buffer << chunk
        while (line = buffer.slice!(/\A.*?\n/))
          next unless line.start_with?("data: ")
          data = line.delete_prefix("data: ").strip
          next if data == "[DONE]" || data.empty?
          event = JSON.parse(data)
          content = event.dig("choices", 0, "delta", "content")
          record[:first] ||= now if content && !content.empty?
          record[:timings] = event["timings"] if event["timings"]
        end
      end
    end
  end
  record[:done] = now
  record
rescue IOError, Errno::EBADF, Errno::ECONNRESET, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
  record.merge(aborted: e.class.name, done: now)
end

def summary(record)
  t = record[:timings] || {}
  { label: record[:label], status: record[:status], aborted: record[:aborted],
    first_word_s: record[:first] && (record[:first] - record[:sent]).round(1), total_s: (record[:done] - record[:sent]).round(1),
    prompt_n: t["prompt_n"], cache_n: t["cache_n"], prompt_ms: t["prompt_ms"]&.round, predicted_n: t["predicted_n"] }.compact
end

def chat_turn(between: nil)
  nonce = SecureRandom.hex(4)
  messages = chat_messages(nonce)
  round1 = call(messages, max_tokens: 60, label: "chat round 1")
  others = Array(between).map { |kind, max| call(send("#{kind}_messages", SecureRandom.hex(4)), max_tokens: max, label: "#{kind} between rounds") }
  answer = "Netflix, Spotify, Adobe Creative Cloud, gym membership and Comcast look like subscriptions."
  round2 = call(messages + [ { role: "assistant", content: answer }, { role: "user", content: "Which one costs the most?" } ],
                max_tokens: 60, label: "chat round 2")
  [ round1, *others, round2 ].map { summary(_1) }
end

def chat_behind(background_kind, abort:)
  bg_http = nil
  background = Thread.new do
    call(send("#{background_kind}_messages", SecureRandom.hex(4)), max_tokens: 300, label: "#{background_kind} (background)",
         on_start: ->(http) { bg_http = http })
  end
  sleep 10
  chat_sent = now
  bg_http&.finish if abort
  chat = call(chat_messages(SecureRandom.hex(4)), max_tokens: 60, label: abort ? "chat, background closed" : "chat, background left running")
  bg = background.value
  { chat_sent_after_bg_s: 10, chat: summary(chat), background: summary(bg),
    background_ended_s_after_chat_sent: (bg[:done] - chat_sent).round(1) }
end

def say(name, value) = puts("#{name}: #{JSON.generate(value)}")

which = ARGV.first || "all"
say "A0 nothing between rounds", chat_turn if %w[all a].include?(which)
say "A1 a 25-transaction merchant call between rounds", chat_turn(between: [ [ :merchant, 200 ] ]) if %w[all a].include?(which)
say "A2 a statement's text (long prompt) between rounds", chat_turn(between: [ [ :statement, 40 ] ]) if %w[all a].include?(which)
say "B1 chat sent during a long prompt read, left running", chat_behind(:statement, abort: false) if %w[all b].include?(which)
say "B2 chat sent during a long prompt read, background closed", chat_behind(:statement, abort: true) if %w[all b].include?(which)
