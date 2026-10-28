Ai::Spike::Model = Data.define(:endpoint, :name, :capabilities, :max_output_tokens, :embedding_dimensions) do
  def initialize(capabilities: [], max_output_tokens: 4096, embedding_dimensions: nil, **rest) = super

  def capable?(*needed) = needed.all? { capabilities.include?(_1.to_s) }
end
