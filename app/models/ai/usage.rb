Ai::Usage = Data.define(:input_tokens, :output_tokens, :cache_read_tokens, :cache_write_tokens, :cost) do
  def self.empty = new(input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0, cost: nil)

  def +(other)
    return self if other.nil?

    with(
      input_tokens: input_tokens.to_i + other.input_tokens.to_i,
      output_tokens: output_tokens.to_i + other.output_tokens.to_i,
      cache_read_tokens: cache_read_tokens.to_i + other.cache_read_tokens.to_i,
      cache_write_tokens: cache_write_tokens.to_i + other.cache_write_tokens.to_i
    )
  end
end
