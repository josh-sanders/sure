# Section 7's JSON-mode strategy for chat-completions servers, the same for
# every Compatible transport: strict -> json_object -> none. `auto` walks that
# chain, moving on after a 400 (retried once without response_format and
# reasoning effort) or when more than half the schema's fields come back null
# (the effort is kept). Parsing is tolerant: <think> blocks, fences, prose.
module Ai::Transport::JsonMode
  CHAIN = %w[strict json_object none].freeze
  NULL_RATIO_LIMIT = 0.5

  private
    # The including transport implements
    #   complete_json(request, mode:, effort:) -> [text, Ai::Usage, raw_id]
    def generate_with_json_mode(request, json_mode:)
      modes = json_mode == "auto" ? CHAIN : [ json_mode ]
      effort = request.reasoning_effort
      usage = Ai::Usage.empty
      last_error = nil

      modes.each_with_index do |mode, index|
        last_attempt = index == modes.size - 1
        begin
          text, call_usage, raw_id = complete_json(request, mode:, effort:)
        rescue Ai::Error::Refused => e
          raise unless e.status == 400 && !last_attempt

          effort = nil   # a 400 drops response_format and effort together (#3605)
          last_error = e
          next
        end
        usage += call_usage

        json = parse_json(text)
        if json.nil? || (json_mode == "auto" && !last_attempt && null_ratio(json, request.schema) > NULL_RATIO_LIMIT)
          last_error = Ai::Error::InvalidOutput.new("#{mode}: #{json.nil? ? "unparseable" : "mostly null"} output")
          raise last_error if last_attempt

          next
        end

        return Ai::Transport::Base::Response.new(json:, usage:, raw_id:)
      end

      raise last_error.is_a?(Ai::Error::Base) ? last_error : Ai::Error::InvalidOutput.new("no usable output")
    end

    def parse_json(text)
      return if text.blank?

      cleaned = text.sub(/\A[\s\S]*<\/think>/, "").strip   # a reasoning model's closed think block
      cleaned = cleaned.sub(/<think>[\s\S]*\z/, "").strip if cleaned.start_with?("<think>")
      candidates = [ cleaned, cleaned[/```(?:json)?\s*(\{[\s\S]*?\})\s*```/, 1], cleaned[/\{[\s\S]*\}/] ].compact
      candidates.each do |candidate|
        parsed = JSON.parse(candidate)
        return parsed if parsed.is_a?(Hash)
      rescue JSON::ParserError
        next
      end
      nil
    end

    def null_ratio(json, schema)
      keys = schema&.dig(:properties)&.keys&.map(&:to_s)
      return 0.0 if keys.blank?

      keys.count { json[_1].nil? || json[_1] == "null" } / keys.size.to_f
    end

    # none mode has no constraint, so the model is shown the shape it must return.
    def schema_example(schema)
      example = schema[:properties].to_h { |key, spec| [ key, Array(spec[:type]).first ] }
      "\n\nRespond with JSON only, no markdown, in exactly this shape:\n#{example.to_json}"
    end
end
