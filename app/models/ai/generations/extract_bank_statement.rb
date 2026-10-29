# Spike: the plan's ExtractBankStatement (the extract_pdf feature), reading a
# statement given as its extracted text, or as files: the PDF itself or its
# pages as images.
class Ai::Generations::ExtractBankStatement < Ai::Generation
  feature :extract_pdf
  prompt  :extract_bank_statement

  MAX_PAGES = 5   # what Provider::Openai::PdfProcessor sends today

  TRANSACTION = {
    type: "object",
    properties: { date: { type: "string" }, description: { type: "string" }, amount: { type: "number" } },
    required: %w[date description amount],
    additionalProperties: false
  }.freeze

  schema({
    type: "object",
    properties: {
      currency:        { type: %w[string null] },
      period_start:    { type: %w[string null] },
      period_end:      { type: %w[string null] },
      opening_balance: { type: %w[number null] },
      closing_balance: { type: %w[number null] },
      transactions:    { type: "array", items: TRANSACTION }
    },
    required: %w[currency period_start period_end opening_balance closing_balance transactions],
    additionalProperties: false
  }.freeze)

  # What can be checked about an extraction without knowing the answer,
  # measured on every recorded extraction (see the note):
  # - reconciles: the opening balance plus every transaction makes the
  #   closing balance. Catches missing, merged, invented and sign-flipped
  #   rows; not dates.
  # - amounts_in_source: every amount appears in the text the model read
  #   (the text layer, or an OCR transcription). nil when it read images.
  # - dates_anchored: the share of rows whose date is the last date printed
  #   within DATE_WINDOW characters before that row's amount. Right
  #   extractions scored 0.62-0.77 (one date can head two rows, and a
  #   statement can list a row twice); wrong dates scored under 0.2. A
  #   heuristic tuned on two statements, not a rule. nil without text.
  # Rows with a zero amount, such as "Balance brought forward", are ignored.
  # A period check (every date inside the reported period) was dropped:
  # models write the period to fit their dates, so it caught nothing, and
  # it flagged a right extraction whose period came from the printed dates.
  DATE_WINDOW = 120
  MIN_DATES_ANCHORED = 0.5

  Checks = Data.define(:reconciles, :amounts_in_source, :dates_anchored) do
    def passed? = reconciles && amounts_in_source != false && (dates_anchored.nil? || dates_anchored >= MIN_DATES_ANCHORED)
  end

  # Picks what a statement goes to the model as (the note's conclusion):
  # page images for a vision model, the text layer otherwise, and
  # Ai::Error::Unavailable for a scan when no vision model is on the route.
  def self.for_pdf(content, vision:, renderer: :pdftoppm, max_pages: MAX_PAGES)
    if vision
      pages = Pdf::PageImages.pages(content, renderer:, max_pages:)
      new(files: pages.each_with_index.map { |png, i| Ai::Transport::Base::Attachment.new(data: png, filename: "page-#{i + 1}.png") })
    else
      text = Pdf::TextExtractor.pages(content, max_pages:).each_with_index.flat_map { |page, i| [ "--- Page #{i + 1} ---", page ] }.join("\n\n")
      raise Ai::Error::Unavailable, "no_text_layer" if text.gsub(/--- Page \d+ ---/, "").strip.empty?

      new(text:)
    end
  end

  # text: the PDF's text layer, or a transcription. files: Ai::Transport::Base::Attachment values.
  def initialize(text: nil, files: [])
    @text, @files = text, files
  end

  def attachments = @files

  def input = @text.nil? ? "The bank statement is attached." : "BANK STATEMENT TEXT:\n#{@text}"

  def checks(value)
    rows = Array(value[:transactions]).reject { _1["amount"].to_f.zero? }
    opening, closing = value.values_at(:opening_balance, :closing_balance)
    reconciles = !opening.nil? && !closing.nil? && rows.any? && (opening + rows.sum { _1["amount"].to_f }).round(2) == closing.round(2)
    source = @text&.gsub(/\s+/, "")&.downcase
    return Checks.new(reconciles:, amounts_in_source: nil, dates_anchored: nil) if source.nil? || rows.empty?

    Checks.new(reconciles:, amounts_in_source: rows.all? { |row| printed_amounts(row["amount"]).any? { source.include?(_1) } },
               dates_anchored: (rows.count { date_anchored?(_1, rows, source) } / rows.size.to_f).round(2))
  end

  private
    # Some occurrence of the row's amount has, as the last date printed (of
    # any row's) in the DATE_WINDOW characters before it, the row's own date.
    def date_anchored?(row, rows, source)
      forms = rows.flat_map { |other| printed_dates(other["date"]).map { [ _1, other["date"] ] } }.uniq
      printed_amounts(row["amount"]).any? do |amount|
        positions(source, amount).any? do |at|
          before = source[[ at - DATE_WINDOW, 0 ].max...at]
          forms.filter_map { |form, date| (index = before.rindex(form)) && [ index, date ] }.max_by(&:first)&.last == row["date"]
        end
      end
    end

    def positions(source, needle)
      Enumerator.new { |found| at = -1; found << at while (at = source.index(needle, at + 1)) }.to_a
    end

    # 2575.0 as "2575.00" or "2,575.00"; 0.26 also as ".26".
    def printed_amounts(amount)
      plain = format("%.2f", amount.to_f.abs)
      [ plain, plain.gsub(/(\d)(?=(\d{3})+\.)/, '\1,'), plain.sub(/\A0\./, ".") ].uniq
    end

    # 2019-02-01 as "02/01", "2/1", "01/02", "1february", "1feb", "february1"…
    def printed_dates(date)
      day = Date.iso8601(date.to_s)
      %w[%m/%d %-m/%-d %d/%m %-d/%-m %-d%B %-d%b %B%-d %b%-d %Y-%m-%d].map { day.strftime(_1).downcase }.uniq
    rescue Date::Error
      []
    end
end
