# Coerces a model's JSON against the feature's schema (section 8.1, step 4):
# "null" -> nil, numeric strings -> numbers, unknown enum values and
# out-of-range numbers -> nil. Anything that isn't an object is InvalidOutput.
module Ai::Schema
  module_function

  def coerce(json, schema)
    raise Ai::Error::InvalidOutput, "expected an object, got #{json.class}" unless json.is_a?(Hash)

    json = json.stringify_keys
    schema[:properties].to_h { |key, spec| [ key.to_sym, coerce_value(json[key.to_s], spec) ] }
  end

  def coerce_value(value, spec)
    value = nil if value.is_a?(String) && (value.strip.empty? || value.strip.casecmp?("null"))
    return nil if value.nil?

    types = Array(spec[:type]).map(&:to_s)
    value = if types.include?("integer") then integer(value)
            elsif types.include?("number") then number(value)
            elsif types.include?("boolean") then [ true, false ].include?(value) ? value : nil
            elsif types.include?("string") then value.is_a?(String) ? value.strip : nil
            else value
            end
    return nil if value.nil?
    return nil if spec[:enum] && !spec[:enum].include?(value)
    return nil if spec[:minimum] && value < spec[:minimum]
    return nil if spec[:maximum] && value > spec[:maximum]

    value
  end

  def number(value)
    Float(value)
  rescue ArgumentError, TypeError
    nil
  end

  def integer(value)
    number = number(value)
    number && number == number.floor ? number.to_i : nil
  end
end
