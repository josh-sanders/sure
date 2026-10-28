# The same Compatible transport, hand-written over ruby-openai, for the
# spike's comparison with the RubyLLM adapter.
class Ai::Transport::HandWritten::Compatible < Ai::Transport::Base
  include Ai::Transport::JsonMode

  def generate(request)
    instrument("generate", model: request.model, request: request.to_h.except(:model)) do
      generate_with_json_mode(request, json_mode: request.json_mode || endpoint.json_mode)
    end
  end

  private
    def client
      @client ||= OpenAI::Client.new(
        access_token: endpoint.api_key.presence || "none",
        uri_base: Ai::Transport::Http.compatible_base(endpoint.base_url),
        request_timeout: endpoint.timeout_seconds,
        extra_headers: Ai::Transport::Http.headers(endpoint),
        log_errors: false,
        &Ai::Transport::Http.faraday(endpoint)
      )
    end

    def complete_json(request, mode:, effort:)
      instructions = mode == "none" ? request.instructions + schema_example(request.schema) : request.instructions
      params = { **endpoint.extra_body, model: request.model.name, messages: [ { role: "system", content: instructions }, { role: "user", content: request.input } ] }
      params[:max_tokens] = request.max_tokens if request.max_tokens
      params[:reasoning_effort] = effort if effort
      case mode
      when "strict" then params[:response_format] = { type: "json_schema", json_schema: { name: request.schema_name, schema: request.schema, strict: true } }
      when "json_object" then params[:response_format] = { type: "json_object" }
      end

      response = mapping_errors { client.chat(parameters: params) }
      usage = response["usage"].to_h
      [ response.dig("choices", 0, "message", "content"),
        usage_from(input: usage["prompt_tokens"], output: usage["completion_tokens"], cache_read: usage.dig("prompt_tokens_details", "cached_tokens")),
        response["id"] ]
    end

    def mapping_errors
      yield
    rescue Faraday::TimeoutError, Net::ReadTimeout => e
      raise Ai::Error::Timeout, e.message
    rescue Faraday::ConnectionFailed => e
      raise Ai::Error::Unreachable, e.message
    rescue Faraday::Error => e
      raise e unless e.response_status

      message = e.response_body.is_a?(Hash) ? e.response_body.dig("error", "message") : e.response_body.to_s
      raise Ai::Error.from_status(e.response_status, message.presence || e.message)
    end
end
