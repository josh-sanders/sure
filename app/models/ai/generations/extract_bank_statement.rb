# Spike: the plan's ExtractBankStatement (the extract_pdf feature), reading a
# statement given as its extracted text, or as files: the PDF itself or its
# pages as images.
class Ai::Generations::ExtractBankStatement < Ai::Generation
  feature :extract_pdf
  prompt  :extract_bank_statement

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

  # text: the PDF's text layer. files: Ai::Transport::Base::Attachment values.
  def initialize(text: nil, files: [])
    @text, @files = text, files
  end

  def attachments = @files

  def input = @text.nil? ? "The bank statement is attached." : "BANK STATEMENT TEXT:\n#{@text}"
end
