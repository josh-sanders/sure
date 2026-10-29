require_relative "spike_helper"

# Spike: what RubyLLM puts on the wire for a statement's files, where there
# was no live server (Anthropic) or no point (the request shape alone).
class Ai::ExtractStatementStubbedTest < ActiveSupport::TestCase
  include AiSpikeHelper

  FILES = Rails.root.join("test/fixtures/files/statements")

  def attachment(name) = Ai::Transport::Base::Attachment.new(data: FILES.join(name).binread, filename: name)

  def statement(files) = Ai::Generations::ExtractBankStatement.new(files:)

  def empty_statement = { currency: nil, period_start: nil, period_end: nil, opening_balance: nil, closing_balance: nil, transactions: [] }

  def anthropic_route = Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint: Ai::Spike::Presets.anthropic(api_key: "sk-ant"), name: "claude-haiku-4-5", max_output_tokens: 4096))

  def stub_anthropic
    stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { id: "msg_1", type: "message", role: "assistant", model: "m", stop_reason: "tool_use", stop_sequence: nil,
              content: [ { type: "tool_use", id: "toolu_1", name: "extract_pdf", input: empty_statement } ],
              usage: { input_tokens: 900, output_tokens: 40 } }.to_json
    )
  end

  def user_content(host) = request_bodies(host).sole["messages"].find { _1["role"] == "user" }["content"]

  test "Anthropic: the PDF goes as a base64 document block, pages as image blocks" do
    stub_anthropic
    statement([ attachment("impact_scanned.pdf") ]).call(route: anthropic_route)
    document = user_content(%r{api.anthropic.com}).find { _1["type"] == "document" }
    assert_equal({ "type" => "base64", "media_type" => "application/pdf" }, document["source"].except("data"))
    assert_equal FILES.join("impact_scanned.pdf").binread, Base64.decode64(document["source"]["data"])

    WebMock::RequestRegistry.instance.reset!
    statement([ attachment("impact_scanned-1.png"), attachment("impact_scanned-2.png") ]).call(route: anthropic_route)
    assert_equal %w[image image text], user_content(%r{api.anthropic.com}).map { _1["type"] }.sort
  end

  test "a file over Anthropic's 24 MB inline limit is sent inline, not uploaded to its Files API" do
    files_api = stub_request(:post, %r{api.anthropic.com/v1/files})
    stub_anthropic
    big = Ai::Transport::Base::Attachment.new(data: "%PDF-1.4\n" + ("0" * 25.megabytes), filename: "big.pdf")

    statement([ big ]).call(route: anthropic_route)

    assert_not_requested files_api
    assert_equal "document", user_content(%r{api.anthropic.com}).find { _1["type"] != "text" }["type"]
  end

  test "an OpenAI-compatible server gets the PDF as a file part with a data URI" do
    stub_request(:post, "http://llama-cpp.test/v1/chat/completions").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { id: "c1", object: "chat.completion", model: LLAMA_MODEL,
              choices: [ { index: 0, finish_reason: "stop", message: { role: "assistant", content: empty_statement.to_json } } ],
              usage: { prompt_tokens: 10, completion_tokens: 10, total_tokens: 20 } }.to_json
    )
    route = llama_route(endpoint: Ai::Spike::Presets.llama_cpp(base_url: "http://llama-cpp.test/v1", json_mode: "strict"))
    events = capture_ai_events { statement([ attachment("bac_ocr.pdf") ]).call(route:) }

    file = user_content(%r{llama-cpp.test}).find { _1["type"] == "file" }["file"]
    assert_equal "bac_ocr.pdf", file["filename"]
    assert file["file_data"].start_with?("data:application/pdf;base64,")
    assert_equal [ { filename: "bac_ocr.pdf", bytes: 256_826 } ], events.sole.payload[:prompt][:attachments], "the event names the file; it never carries it"
  end

  test "the hand-written transports refuse attachments rather than drop them" do
    assert_raises(Ai::Error::Refused) { statement([ attachment("bac_ocr.pdf") ]).call(route: anthropic_route, hand_written: true) }
    assert_raises(Ai::Error::Refused) { statement([ attachment("bac_ocr.pdf") ]).call(route: llama_route, hand_written: true) }
  end
end
