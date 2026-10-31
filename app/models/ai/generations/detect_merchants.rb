# Spike (async): today's Provider::Openai::AutoMerchantDetector as an
# Ai::Generation, with the simplified instructions custom providers get. One
# batch of transactions per call (LLM_MAX_ITEMS_PER_CALL, 25 by default).
class Ai::Generations::DetectMerchants < Ai::Generation
  feature :detect_merchants
  prompt  :detect_merchants

  schema({
    type: "object",
    properties: {
      merchants: {
        type: "array",
        items: {
          type: "object",
          properties: {
            transaction_id: { type: "string" },
            business_name:  { type: %w[string null] },
            business_url:   { type: %w[string null] }
          },
          required: %w[transaction_id business_name business_url],
          additionalProperties: false
        }
      }
    },
    required: %w[merchants],
    additionalProperties: false
  }.freeze)

  # transactions: [{ id:, name: }]; user_merchants: names.
  def initialize(transactions:, user_merchants: [])
    @transactions, @user_merchants = transactions, user_merchants
  end

  def input
    {
      transactions: @transactions.map { { transaction_id: _1[:id], name: _1[:name] } },
      user_merchants: @user_merchants.map { { name: _1 } }
    }.to_json
  end
end
