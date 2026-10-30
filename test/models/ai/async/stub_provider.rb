# A stand-in for a cloud provider's chat completions endpoint, run as its own
# process by the async spike: every POST waits DELAY seconds and answers with
# one bill setup; a streamed request gets its first chunk after a quarter of
# DELAY and the rest over the remainder. Above LIMIT requests in flight it answers 429 with
# Retry-After: 1, as a provider's rate limit would. GET /stats reports what it
# saw; POST /reset clears it. Listens on 127.0.0.1 only and prints its port.
#
#   ruby stub_provider.rb DELAY [LIMIT]
require "socket"
require "json"

DELAY = Float(ARGV.fetch(0, "2"))
LIMIT = ARGV[1]&.then { Integer(_1) }

ANSWER = { name: "Netflix", amount: 15.49, frequency: "monthly", day_of_month: 15, weekday: nil, month_of_year: nil,
           category_name: "Entertainment", bill_type: "subscription", autopay: true, confidence: 0.9, rationale: "Monthly." }.to_json
COMPLETION = {
  id: "stub", object: "chat.completion", created: 0, model: "stub-model",
  choices: [ { index: 0, message: { role: "assistant", content: ANSWER }, finish_reason: "stop" } ],
  usage: { prompt_tokens: 500, completion_tokens: 60, total_tokens: 560 }
}.to_json
RATE_LIMITED = { error: { message: "Rate limit reached", type: "rate_limit_exceeded", code: "rate_limit_exceeded" } }.to_json

$lock = Mutex.new
$stats = { served: 0, rate_limited: 0, in_flight: 0, peak: 0 }

def respond(client, status, body, extra = {})
  headers = { "Content-Type" => "application/json", "Content-Length" => body.bytesize, "Connection" => "close" }.merge(extra)
  client.write("HTTP/1.1 #{status}\r\n#{headers.map { "#{_1}: #{_2}" }.join("\r\n")}\r\n\r\n#{body}")
end

CHUNKS = [ "Your ", "Netflix ", "bill ", "is ", "monthly." ].freeze

def stream(client)
  client.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n")
  sleep DELAY / 4.0
  CHUNKS.each_with_index do |text, i|
    sleep DELAY * 0.75 / CHUNKS.size if i.positive?
    client.write("data: #{{ id: "stub", object: "chat.completion.chunk", model: "stub-model", choices: [ { index: 0, delta: { content: text } } ] }.to_json}\n\n")
  end
  client.write("data: #{{ id: "stub", object: "chat.completion.chunk", model: "stub-model", choices: [ { index: 0, delta: {}, finish_reason: "stop" } ],
                         usage: { prompt_tokens: 500, completion_tokens: 5, total_tokens: 505 } }.to_json}\n\ndata: [DONE]\n\n")
end

def handle(client)
  request_line = client.gets or return
  method, path = request_line.split
  length = 0
  while (line = client.gets) && line != "\r\n"
    length = line.split(":", 2).last.to_i if line.downcase.start_with?("content-length:")
  end
  body = length.positive? ? client.read(length) : ""

  case [ method, path ]
  in [ "GET", "/stats" ] then respond(client, "200 OK", $lock.synchronize { $stats.to_json })
  in [ "POST", "/reset" ]
    $lock.synchronize { $stats.transform_values! { 0 } }
    respond(client, "200 OK", "{}")
  in [ "POST", _ ]
    admitted = $lock.synchronize do
      if LIMIT && $stats[:in_flight] >= LIMIT
        $stats[:rate_limited] += 1
        false
      else
        $stats[:in_flight] += 1
        $stats[:peak] = [ $stats[:peak], $stats[:in_flight] ].max
        true
      end
    end
    return respond(client, "429 Too Many Requests", RATE_LIMITED, "Retry-After" => "1") unless admitted

    begin
      body.include?('"stream":true') ? stream(client) : (sleep DELAY; respond(client, "200 OK", COMPLETION))
    ensure
      $lock.synchronize do
        $stats[:in_flight] -= 1
        $stats[:served] += 1
      end
    end
  else respond(client, "404 Not Found", "{}")
  end
rescue IOError, SystemCallError
  nil
ensure
  client.close
end

server = TCPServer.new("127.0.0.1", 0)
server.listen(1024)
$stdout.puts server.addr[1]
$stdout.flush
loop { Thread.new(server.accept) { handle(_1) } }
