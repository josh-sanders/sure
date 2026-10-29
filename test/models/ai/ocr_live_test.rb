require_relative "spike_helper"
require_relative "statement_scoring"

# Spike: Unlimited-OCR-2 (baidu, 3.3B MoE) on llama.cpp, CPU only, from two
# GGUF conversions (AtomicChat's and RX5950XT's), reading the two sample
# statements' pages rendered by pdftoppm and by ruby-vips at Sure's 150 dpi.
#
# Two steps, recorded apart, because the venus server holds one model at a
# time:
# - "transcribes": the OCR model, loaded on SPIKE_LLAMA_CPP_URL, turns the
#   pages into text with the model card's prompt, "<PAGE><image>" per page
#   then "Multi page parsing.". AtomicChat's chat template writes it around
#   images sent alone; RX5950XT's doesn't, so the request spells it out.
# - "extracts": Qwen3.6, loaded again later, extracts the statement from the
#   recorded transcription, scored like the other statement tests.
# Requests run one at a time: everything shares the CPU.
class Ai::OcrLiveTest < ActiveSupport::TestCase
  include AiSpikeHelper
  include StatementScoring

  RENDERERS = %i[pdftoppm vips].freeze
  TRANSCRIBE = "Transcribe every page of this bank statement to Markdown, exactly as printed. Write each table " \
               "as a Markdown table, one row per line, with | between cells. Output only the transcription.".freeze

  # What each run did, recorded live; a combination not recorded yet skips.
  EXPECTED_TRANSCRIPTIONS = {
    [ :atomicchat, :pdftoppm, "bac_ocr" ] => { pages: 1, output_tokens: 1009, finish: :stop, chars: 2256, amounts: 13, of: 13 },
    [ :atomicchat, :pdftoppm, "impact_scanned" ] => { pages: 2, output_tokens: 2070, finish: :stop, chars: 4097, amounts: 21, of: 21 },
    [ :atomicchat, :vips, "bac_ocr" ] => { pages: 1, output_tokens: 1061, finish: :stop, chars: 2506, amounts: 13, of: 13 },
    [ :atomicchat, :vips, "impact_scanned" ] => { pages: 2, output_tokens: 2064, finish: :stop, chars: 4095, amounts: 21, of: 21 },
    [ :rx5950xt, :pdftoppm, "bac_ocr" ] => { pages: 1, output_tokens: 1009, finish: :stop, chars: 2256, amounts: 13, of: 13 },
    [ :rx5950xt, :pdftoppm, "impact_scanned" ] => { pages: 2, output_tokens: 2064, finish: :stop, chars: 4095, amounts: 21, of: 21 },
    [ :rx5950xt, :vips, "bac_ocr" ] => { pages: 1, output_tokens: 1009, finish: :stop, chars: 2255, amounts: 13, of: 13 },
    [ :rx5950xt, :vips, "impact_scanned" ] => { pages: 2, output_tokens: 2064, finish: :stop, chars: 4095, amounts: 21, of: 21 },
    [ :rx5950xt_special, :pdftoppm, "bac_ocr" ] => { pages: 1, output_tokens: 1009, finish: :stop, chars: 3169, amounts: 13, of: 13 },
    [ :rx5950xt_special, :pdftoppm, "impact_scanned" ] => { pages: 2, output_tokens: 2064, finish: :stop, chars: 6604, amounts: 21, of: 21 },
    [ :wevisone, :pdftoppm, "bac_ocr" ] => { pages: 1, output_tokens: 1078, finish: :stop, chars: 3788, amounts: 13, of: 13 },
    [ :wevisone, :vips, "bac_ocr" ] => { pages: 1, output_tokens: 1048, finish: :stop, chars: 3691, amounts: 11, of: 13 }
  }.freeze
  # Qwen3.6 from each transcription. WeVisOne's left out BAC's date column,
  # so Qwen dated ten rows from their descriptions: every amount and sign
  # right, and one run still reconciles, so reconciling can't catch dates.
  EXPECTED_EXTRACTIONS = {
    [ :atomicchat, :pdftoppm, "bac_ocr" ] => { matched: 13, of: 13, extra: 1, balances: true, reconciles: true, checks: { reconciles: true, amounts_in_source: true, dates_anchored: 0.77, passed: true } },
    [ :atomicchat, :pdftoppm, "impact_scanned" ] => { matched: 21, of: 21, extra: 0, balances: true, reconciles: true, checks: { reconciles: true, amounts_in_source: true, dates_anchored: 0.62, passed: true } },
    [ :atomicchat, :vips, "bac_ocr" ] => { matched: 13, of: 13, extra: 0, balances: true, reconciles: true, checks: { reconciles: true, amounts_in_source: true, dates_anchored: 0.77, passed: true } },
    [ :atomicchat, :vips, "impact_scanned" ] => { matched: 21, of: 21, extra: 0, balances: true, reconciles: true, checks: { reconciles: true, amounts_in_source: true, dates_anchored: 0.62, passed: true } },
    [ :rx5950xt, :pdftoppm, "bac_ocr" ] => { matched: 13, of: 13, extra: 0, balances: true, reconciles: true, checks: { reconciles: true, amounts_in_source: true, dates_anchored: 0.77, passed: true } },
    [ :rx5950xt, :pdftoppm, "impact_scanned" ] => { matched: 21, of: 21, extra: 0, balances: true, reconciles: true, checks: { reconciles: true, amounts_in_source: true, dates_anchored: 0.62, passed: true } },
    [ :rx5950xt, :vips, "bac_ocr" ] => { matched: 13, of: 13, extra: 1, balances: true, reconciles: true, checks: { reconciles: true, amounts_in_source: true, dates_anchored: 0.77, passed: true } },
    [ :rx5950xt, :vips, "impact_scanned" ] => { matched: 21, of: 21, extra: 0, balances: true, reconciles: true, checks: { reconciles: true, amounts_in_source: true, dates_anchored: 0.62, passed: true } },
    [ :wevisone, :pdftoppm, "bac_ocr" ] => { matched: 3, of: 13, extra: 10, balances: true, reconciles: true, checks: { reconciles: true, amounts_in_source: true, dates_anchored: 0.08, passed: false } },
    [ :wevisone, :vips, "bac_ocr" ] => { matched: 3, of: 13, extra: 10, balances: true, reconciles: false, checks: { reconciles: false, amounts_in_source: false, dates_anchored: 0.15, passed: false } }
  }.freeze
  # WeVisOne straight to JSON: grounding tags in the descriptions, invented
  # years, and loops to the token cap at 7.9 tokens a second, so the BAC run
  # took 26 minutes over the auto chain's three attempts.
  EXPECTED_DIRECT = {
    [ :wevisone, :pdftoppm, "bac_ocr" ] => "InvalidOutput: none: unparseable output",
    [ :wevisone, :pdftoppm, "impact_scanned" ] => { matched: 0, of: 21, extra: 0, balances: true, reconciles: false, checks: { reconciles: false, amounts_in_source: nil, dates_anchored: nil, passed: false } },
    [ :wevisone, :vips, "impact_scanned" ] => { matched: 0, of: 21, extra: 0, balances: true, reconciles: false, checks: { reconciles: false, amounts_in_source: nil, dates_anchored: nil, passed: false } }
  }.freeze

  def recorded?(name) = Rails.root.join("test/vcr_cassettes/ai/#{name}.yml").exist?

  def pdftoppm? = system("pdftoppm", "-v", out: File::NULL, err: File::NULL)

  def pages(statement, renderer) = Pdf::PageImages.pages(FILES.join("#{statement}.pdf").binread, renderer:)

  def transcribe(variant, pages)
    endpoint = Ai::Spike::Presets.llama_cpp(timeout_seconds: 1800, max_retries: 0)
    model = Ai::Spike::Model.new(endpoint:, name: Ai::Spike::Presets::OCR.fetch(variant)[:model], max_output_tokens: 8000)
    attachments = pages.each_with_index.map { |png, i| Ai::Transport::Base::Attachment.new(data: png, filename: "page-#{i + 1}.png") }
    messages =
      case Ai::Spike::Presets::OCR.fetch(variant)[:prompt]
      when :template then [ Ai::Transport::Base::Message.new(role: :user, content: nil, attachments:) ]
      when :instruction then [ Ai::Transport::Base::Message.new(role: :user, content: TRANSCRIBE, attachments:) ]
      else
        # RubyLLM puts a message's text before its files, so one message per
        # page gives "<PAGE><image>", and the template joins them.
        attachments.map { Ai::Transport::Base::Message.new(role: :user, content: "<PAGE>", attachments: [ _1 ]) } +
          [ Ai::Transport::Base::Message.new(role: :user, content: "Multi page parsing.") ]
      end
    Ai::Transport.for(endpoint).converse(Ai::Transport::Base::ConverseRequest.new(model:, instructions: nil, messages:, max_tokens: 8000))
  end

  def cassette(variant, renderer, statement, step) = "ocr/#{variant}_#{renderer}_#{statement}_#{step}"

  # The recorded transcription, replayed whatever is loaded now.
  def recorded_transcription(variant, renderer, statement)
    VCR.use_cassette("ai/#{cassette(variant, renderer, statement, :transcribe)}", record: :none, match_requests_on: %i[method uri]) do
      transcribe(variant, pages(statement, renderer)).text
    end
  end

  # How many of the statement's amounts appear in the transcription, as
  # printed, with or without a thousands separator.
  def amounts_found(text, truth)
    truth[:transactions].count do |_, amount|
      plain = format("%.2f", amount.abs)
      [ plain, plain.sub(/\A(\d+)(\d{3})\./, '\1,\2.') ].uniq.any? { text.include?(_1) }
    end
  end

  def timed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    [ yield, (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1) ]
  end

  def report(line) = (puts "\n  #{line}" if recording? || ENV["SPIKE_PRINT"])

  # Without --special, llama-server drops the model's table tags, so cells
  # run together ("24.5039,975.50"). With it, the same tokens (1,009 and
  # 2,064 either way) arrive as HTML, and so does the end-of-sequence token.
  test "--special keeps the table tags, and the end-of-sequence token" do
    without, with = %i[rx5950xt rx5950xt_special].map { recorded_transcription(_1, :pdftoppm, "bac_ocr") }

    assert_equal [ 0, 84 ], [ without, with ].map { _1.scan("</td>").size }
    assert_includes without, "24.5039,975.50"
    assert_includes with, "<td>24.50</td><td></td><td>39,975.50</td>"
    assert with.end_with?("<｜end▁of▁sentence｜>"), "Sure has to strip it"
    assert_not_includes without, "end▁of▁sentence"
  end

  Ai::Spike::Presets::OCR.each_key do |variant|
    RENDERERS.each do |renderer|
      STATEMENTS.each do |statement, truth|
        test "#{variant}, #{renderer}: transcribes #{statement} (live)" do
          skip "pdftoppm isn't installed" if renderer == :pdftoppm && !pdftoppm?
          skip "not recorded yet" unless recording? || recorded?(cassette(variant, renderer, statement, :transcribe))

          images = pages(statement, renderer)
          with_spike_cassette(cassette(variant, renderer, statement, :transcribe)) do
            @turn, @seconds = timed { transcribe(variant, images) }
          end

          @summary = { pages: images.size, output_tokens: @turn.usage.output_tokens, finish: @turn.finish_reason,
                       chars: @turn.text.size, amounts: amounts_found(@turn.text, truth), of: truth[:transactions].size }
          report "#{variant} #{renderer} #{statement} transcribe: #{@summary.inspect} #{@seconds}s"
          File.write(Rails.root.join("tmp/ocr_#{variant}_#{renderer}_#{statement}.md"), @turn.text) if recording?
          assert_equal EXPECTED_TRANSCRIPTIONS.fetch([ variant, renderer, statement ]), @summary unless recording?
        end

        if Ai::Spike::Presets::OCR.fetch(variant)[:prompt] == :instruction
          test "#{variant}, #{renderer}: extracts #{statement} straight from the page images (live)" do
            skip "pdftoppm isn't installed" if renderer == :pdftoppm && !pdftoppm?
            skip "not recorded yet" unless recording? || recorded?(cassette(variant, renderer, statement, :direct))

            files = pages(statement, renderer).each_with_index.map { |png, i| Ai::Transport::Base::Attachment.new(data: png, filename: "page-#{i + 1}.png") }
            endpoint = Ai::Spike::Presets.llama_cpp(timeout_seconds: 1800, max_retries: 0)
            route = Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint:, name: Ai::Spike::Presets::OCR.fetch(variant)[:model], max_output_tokens: 6000))
            with_spike_cassette(cassette(variant, renderer, statement, :direct)) do
              @result, @seconds = timed do
                (@generation = Ai::Generations::ExtractBankStatement.new(files:)).call(route:)
              rescue Ai::Error::Base => e
                e
              end
            end

            @summary = @result.is_a?(Exception) ? "#{@result.class.name.demodulize}: #{@result.message.truncate(120)}" : score(@result.value, truth).merge(checks: checked(@generation, @result.value))
            report "#{variant} #{renderer} #{statement} direct: #{@summary.inspect} requests=#{WebMock::RequestRegistry.instance.requested_signatures.hash.values.sum} #{@seconds}s"
            assert_equal EXPECTED_DIRECT.fetch([ variant, renderer, statement ]), @summary unless recording?
          end
        end

        test "#{variant}, #{renderer}: Qwen3.6 extracts #{statement} from the transcription (live)" do
          skip "pdftoppm isn't installed" if renderer == :pdftoppm && !pdftoppm?
          skip "no transcription recorded yet" unless recorded?(cassette(variant, renderer, statement, :transcribe))
          skip "not recorded yet" unless recording? || recorded?(cassette(variant, renderer, statement, :extract))

          text = recorded_transcription(variant, renderer, statement)
          with_spike_cassette(cassette(variant, renderer, statement, :extract)) do
            @result, @seconds = timed do
              (@generation = Ai::Generations::ExtractBankStatement.new(text:)).call(route: llama_route(endpoint: Ai::Spike::Presets.llama_cpp(timeout_seconds: 900)))
            rescue Ai::Error::Base => e
              e
            end
          end

          @summary = @result.is_a?(Exception) ? "#{@result.class.name.demodulize}: #{@result.message.truncate(120)}" : score(@result.value, truth).merge(checks: checked(@generation, @result.value))
          report "#{variant} #{renderer} #{statement} extract: #{@summary.inspect} #{@seconds}s"
          assert_equal EXPECTED_EXTRACTIONS.fetch([ variant, renderer, statement ]), @summary unless recording?
        end
      end
    end
  end
end
