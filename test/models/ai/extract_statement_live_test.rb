require_relative "spike_helper"

# Spike: reading a bank statement through RubyLLM's generate, live. Each
# statement goes as Sure's text path sends it today (the PDF's text layer),
# as the PDF itself (RubyLLM's file part), and as page images (Sure's
# fallback for scans, rendered by pdftoppm at 150 dpi as Sure does).
#
# Two public sample statements (test/fixtures/files/statements/):
# - bac_ocr: one page, an OCR'd text layer with errors (run-together
#   words, "£44.079.83"), 13 transactions. Its own "Total money in" is
#   £5,474.00; the transactions and balances make £5,475.00.
# - impact_scanned: two pages, no text layer. The same 21 transactions are
#   listed by date on page 1 and again by type on page 2, and the pages
#   disagree on one: page 1 has 10/08 -59.08, page 2 10/07 -31.57.
class Ai::ExtractStatementLiveTest < ActiveSupport::TestCase
  include AiSpikeHelper

  FILES = Rails.root.join("test/fixtures/files/statements")

  STATEMENTS = {
    "bac_ocr" => {
      opening: 40_000.0, closing: 44_079.83,
      transactions: [ [ "02-01", -24.5 ], [ "02-01", -20.0 ], [ "02-03", -30.0 ], [ "02-04", 2575.0 ], [ "02-11", 300.0 ],
                      [ "02-16", -50.0 ], [ "02-17", -40.0 ], [ "02-17", -78.34 ], [ "02-18", 2575.0 ], [ "02-18", -15.0 ],
                      [ "02-24", -150.0 ], [ "02-24", 25.0 ], [ "02-28", -987.33 ] ]
    },
    "impact_scanned" => {
      opening: 69.96, closing: 586.71,
      transactions: [ [ "10-02", -4.23 ], [ "10-03", 763.01 ], [ "10-04", -11.68 ], [ "10-05", -9.98 ], [ "10-05", -25.5 ],
                      [ "10-08", -59.08 ], [ "10-12", -69.0 ], [ "10-14", -180.63 ], [ "10-14", -18.96 ], [ "10-16", 763.01 ],
                      [ "10-22", -140.0 ], [ "10-28", -91.06 ], [ "10-30", -451.2 ], [ "10-30", -37.07 ], [ "10-30", -18.67 ],
                      [ "10-31", -100.0 ], [ "10-31", -78.24 ], [ "10-31", 350.0 ], [ "11-02", -52.23 ], [ "11-09", 0.26 ],
                      [ "11-09", -12.0 ] ],
      alternatives: { [ "10-08", -59.08 ] => [ "10-07", -31.57 ] }
    }
  }.freeze

  # What each server did, recorded live (see the note's table).
  EXPECTED = {
    [ "gemini", "bac_ocr", "file" ] => "Refused: Invalid content part type: file",
    [ "gemini", "bac_ocr", "images" ] => { matched: 13, of: 13, extra: 0, balances: true, reconciles: true, input: 1252 },
    [ "gemini", "bac_ocr", "text" ] => { matched: 13, of: 13, extra: 0, balances: true, reconciles: true, input: 805 },
    [ "gemini", "impact_scanned", "file" ] => "Refused: Invalid content part type: file",
    [ "gemini", "impact_scanned", "images" ] => { matched: 21, of: 21, extra: 0, balances: true, reconciles: true, input: 2354 },
    [ "gemini", "impact_scanned", "text" ] => { matched: 0, of: 21, extra: 0, balances: false, reconciles: false, input: 531 },
    [ "llama_cpp", "bac_ocr", "file" ] => "Refused: unsupported content[].type",
    [ "llama_cpp", "bac_ocr", "images" ] => "Upstream: image input is not supported - hint: if this is unexpected, you may need to provide the mmproj",
    [ "llama_cpp", "bac_ocr", "text" ] => { matched: 13, of: 13, extra: 0, balances: true, reconciles: true, input: 811 },
    [ "llama_cpp", "impact_scanned", "file" ] => "Refused: unsupported content[].type",
    [ "llama_cpp", "impact_scanned", "images" ] => "Upstream: image input is not supported - hint: if this is unexpected, you may need to provide the mmproj",
    [ "llama_cpp", "impact_scanned", "text" ] => { matched: 0, of: 21, extra: 0, balances: false, reconciles: false, input: 551 },
    [ "openrouter_lightning", "bac_ocr", "file" ] => { matched: 2, of: 13, extra: 9, balances: true, reconciles: false, input: 1216 },
    [ "openrouter_lightning", "bac_ocr", "images" ] => "Refused: No endpoints found that support image input",
    [ "openrouter_lightning", "bac_ocr", "text" ] => { matched: 9, of: 13, extra: 4, balances: true, reconciles: false, input: 825 },
    [ "openrouter_lightning", "impact_scanned", "file" ] => { matched: 0, of: 21, extra: 0, balances: false, reconciles: false, input: 1855 },
    [ "openrouter_lightning", "impact_scanned", "images" ] => "Refused: No endpoints found that support image input",
    [ "openrouter_lightning", "impact_scanned", "text" ] => { matched: 0, of: 21, extra: 0, balances: false, reconciles: false, input: 538 },
    [ "openrouter_vl", "bac_ocr", "file" ] => { matched: 5, of: 13, extra: 8, balances: true, reconciles: false, input: 1216 },
    [ "openrouter_vl", "bac_ocr", "images" ] => { matched: 13, of: 13, extra: 1, balances: true, reconciles: true, input: 1325 },
    [ "openrouter_vl", "impact_scanned", "file" ] => { matched: 0, of: 21, extra: 0, balances: false, reconciles: false, input: 1855 },
    [ "openrouter_vl", "impact_scanned", "images" ] => { matched: 21, of: 21, extra: 0, balances: true, reconciles: true, input: 8654 }
  }.freeze

  def self.servers
    {
      "llama_cpp" => { forms: %w[text file images], route: -> { llama_route(endpoint: Ai::Spike::Presets.llama_cpp(timeout_seconds: 900, max_retries: 0)) } },
      "gemini" => { forms: %w[text file images], route: -> { route(Ai::Spike::Presets.gemini(api_key: ENV.fetch("SPIKE_GEMINI_API_KEY", "gemini-key"), max_retries: 0), "gemini-3.5-flash-lite") } },
      # Effort none: with reasoning on, Lightning spent all 8,192 output tokens on it, every time.
      "openrouter_lightning" => { forms: %w[text file images], route: -> { route(openrouter, "nvidia/nemotron-3.5-lightning:free", reasoning_effort: "none") } },
      # google/gemma-4-31b-it:free answered every request with a 429 on the day.
      "openrouter_vl" => { forms: %w[file images], route: -> { route(openrouter, "nvidia/nemotron-3.5-super-vl:free", reasoning_effort: "none") } }
    }
  end

  # OpenRouter parses a PDF for the model. Its default engine OCRs a scan and
  # bills it, even for a free model (below); pdf-text is free and reads only a
  # text layer.
  FREE_PDF_ENGINE = { plugins: [ { id: "file-parser", pdf: { engine: "pdf-text" } } ] }.freeze

  def route(endpoint, name, reasoning_effort: nil)
    Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint:, name:, max_output_tokens: 8192), reasoning_effort:)
  end

  def openrouter
    Ai::Spike::Presets.openrouter(api_key: ENV.fetch("SPIKE_OPENROUTER_API_KEY", "or-key"), json_mode: "auto", max_retries: 0,
                                  timeout_seconds: 300, extra_body: FREE_PDF_ENGINE)
  end

  def generation(statement, form)
    pdf = FILES.join("#{statement}.pdf").binread
    case form
    when "text"
      text = Pdf::TextExtractor.pages(pdf).each_with_index.flat_map { |page, i| [ "--- Page #{i + 1} ---", page ] }.join("\n\n")
      Ai::Generations::ExtractBankStatement.new(text:)
    when "file" then Ai::Generations::ExtractBankStatement.new(files: [ attachment(FILES.join("#{statement}.pdf")) ])
    when "images" then Ai::Generations::ExtractBankStatement.new(files: Dir[FILES.join("#{statement}-*.png")].sort.map { attachment(_1) })
    end
  end

  def attachment(path) = Ai::Transport::Base::Attachment.new(data: File.binread(path), filename: File.basename(path))

  # Transactions matched on month-day and signed amount, each at most once.
  # reconciles: the opening balance plus every transaction makes the closing
  # one, a check Sure could run on any extraction without knowing the answer.
  def score(value, truth)
    got = Array(value[:transactions]).map { |t| [ t["date"].to_s[5, 5], t["amount"].to_f.round(2) ] }
    remaining = got.dup
    matched = truth[:transactions].count do |expected|
      index = remaining.index(expected) || remaining.index(truth.dig(:alternatives, expected))
      remaining.delete_at(index) if index
    end
    opening, closing = value.values_at(:opening_balance, :closing_balance)
    { matched:, of: truth[:transactions].size, extra: remaining.size, balances: [ opening, closing ] == truth.values_at(:opening, :closing),
      reconciles: !opening.nil? && !closing.nil? && (opening + got.sum(&:last)).round(2) == closing.round(2) }
  end

  # What each request carried besides text, from the bodies sent.
  def parts_sent
    WebMock::RequestRegistry.instance.requested_signatures.hash.keys.map do |signature|
      JSON.parse(signature.body)["messages"].flat_map { |m| Array(m["content"]).filter_map { _1["type"] if _1.is_a?(Hash) && _1["type"] != "text" } }
    end
  end

  # The first OpenRouter run sent the PDF with no plugin, so OpenRouter chose
  # the engine, and Lightning still reasoned. Read from its cassettes, never
  # re-recorded: every request costs.
  test "OpenRouter's default PDF engine OCRs a scan for a free model, and bills each request" do
    { "bac_ocr" => 0.002, "impact_scanned" => 0.004 }.each do |statement, cost|
      interactions = YAML.load_file(Rails.root.join("test/vcr_cassettes/ai/statements/openrouter_default_engine_#{statement}_file.yml"))["http_interactions"]
      bodies = interactions.map { JSON.parse(_1["response"]["body"]["string"]) }
      assert_equal [ cost ] * 3, bodies.map { _1.dig("usage", "cost") }, "#{statement}: one parse per request; the auto chain sent three"
      assert bodies.all? { _1.dig("choices", 0, "message", "annotations", 0, "type") == "file" }, "the parsed file comes back as an annotation"
      assert interactions.none? { JSON.parse(_1["request"]["body"]["string"]).key?("plugins") }
    end
    reasoning = YAML.load_file(Rails.root.join("test/vcr_cassettes/ai/statements/openrouter_default_engine_impact_scanned_file.yml"))
                    .dig("http_interactions", 0, "response", "body", "string").then { JSON.parse(_1).dig("choices", 0, "message", "reasoning") }
    assert_includes reasoning, "763.01", "the model saw the scanned transactions"
  end

  servers.each do |server, config|
    config[:forms].each do |form|
      STATEMENTS.each do |statement, truth|
        test "#{server}: #{statement} as #{form} (live)" do
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          with_spike_cassette("statements/#{server}_#{statement}_#{form}") do
            @outcome = begin
              generation(statement, form).call(route: instance_exec(&config[:route]))
            rescue Ai::Error::Base => e
              e
            end
          end

          summary = @outcome.is_a?(Exception) ? "#{@outcome.class.name.demodulize}: #{@outcome.message.truncate(160)}" : score(@outcome.value, truth).merge(input: @outcome.usage.input_tokens + @outcome.usage.cache_read_tokens)
          puts "\n  #{server} #{statement} #{form}: #{summary.inspect} requests=#{parts_sent.size} parts=#{parts_sent.inspect} #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)}s" if recording? || ENV["SPIKE_PRINT"]
          assert_equal EXPECTED.fetch([ server, statement, form ]), summary
        end
      end
    end
  end
end
