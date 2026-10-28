class Ai::Generations::SuggestBillSetup < Ai::Generation
  feature :bill_setup
  prompt  :bill_setup

  schema({
    type: "object",
    properties: {
      name:          { type: %w[string null] },
      amount:        { type: %w[number null] },
      frequency:     { type: %w[string null], enum: RecurringTransaction::FrequencyPreset::PRESETS + [ nil ] },
      day_of_month:  { type: %w[integer null], minimum: 1, maximum: 31 },
      weekday:       { type: %w[integer null], minimum: 0, maximum: 6 },
      month_of_year: { type: %w[integer null], minimum: 1, maximum: 12 },
      category_name: { type: %w[string null] },
      bill_type:     { type: %w[string null], enum: [ "bill", "subscription", "installment", nil ] },
      autopay:       { type: %w[boolean null] },
      confidence:    { type: %w[number null], minimum: 0, maximum: 1 },
      rationale:     { type: %w[string null] }
    },
    required: %w[name amount frequency day_of_month weekday month_of_year category_name bill_type autopay confidence rationale],
    additionalProperties: false
  }.freeze)

  def initialize(charges:, categories:, current_config: nil)
    @charges, @categories, @current_config = charges, categories, current_config
  end

  def prompt_locals = { configure_mode: @current_config.present? }

  def input
    lines = @charges.map { |c| "- #{c[:date]} #{c[:amount]} #{c[:name]}" }
    <<~TEXT
      CHARGE HISTORY (date amount description):
      #{lines.join("\n")}

      AVAILABLE CATEGORIES: #{@categories.join(", ")}
      #{"CURRENT CONFIGURATION:\n#{@current_config.to_json}" if @current_config.present?}
    TEXT
  end
end
