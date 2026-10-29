# Anthropic hand-written over the anthropic gem: one forced tool, or `auto`
# plus one retry for models that can't be forced (#4513).
class Ai::Transport::HandWritten::Anthropic < Ai::Transport::Base
  def generate(request)
    # The spike didn't port today's per-provider PDF handling here.
    raise Ai::Error::Refused, "the hand-written transport doesn't send attachments" if request.attachments.any?

    instrument("generate", model: request.model, request: event_request(request)) do
      tool = request.schema_name
      forced = Provider::Anthropic.forced_tool_choice_supported?(request.model.name)
      params = {
        model: request.model.name,
        max_tokens: request.max_tokens || 4096,
        system_: Provider::Anthropic.structured_output_system(request.instructions, request.model.name, tool),
        messages: [ { role: "user", content: request.input } ],
        tools: [ { name: tool, description: "Report the result.", input_schema: request.schema } ],
        tool_choice: Provider::Anthropic.structured_output_tool_choice(request.model.name, tool)
      }

      response = create(params)
      usage = usage_of(response)
      if !forced && tool_input(response, tool).nil? && response.stop_reason.to_s == "end_turn"
        text = Array(response.content).filter_map { _1.text if _1.type.to_s == "text" }.join("\n").strip
        retry_messages = [ (text.present? ? { role: "assistant", content: text } : nil),
                           { role: "user", content: "You did not call the #{tool} tool. Call it now with the result; do not answer with text." } ].compact
        response = create(params.merge(messages: params[:messages] + retry_messages))
        usage += usage_of(response)
      end

      json = tool_input(response, tool)
      raise Ai::Error::InvalidOutput, "Model did not call #{tool} (#{response.stop_reason})" unless json

      Response.new(json:, usage:, raw_id: response.id)
    end
  end

  private
    # The anthropic gem opens Net::HTTP itself and takes no proxy option.
    # Net::HTTP reads http_proxy/HTTP_PROXY even for TLS and ignores
    # HTTPS_PROXY, so an HTTPS_PROXY-only install goes direct (spike proxy check).
    def client
      @client ||= ::Anthropic::Client.new(api_key: endpoint.api_key, base_url: endpoint.base_url,
                                          timeout: endpoint.timeout_seconds, max_retries: endpoint.max_retries)
    end

    def create(params)
      client.messages.create(**params, request_options: { extra_headers: Ai::Transport::Http.headers(endpoint) })
    rescue ::Anthropic::Errors::APITimeoutError => e
      raise Ai::Error::Timeout, e.message
    rescue ::Anthropic::Errors::APIConnectionError => e
      raise Ai::Error::Unreachable, e.message
    rescue ::Anthropic::Errors::APIStatusError => e
      raise Ai::Error.from_status(e.status, e.message)
    end

    def tool_input(response, tool)
      block = Array(response.content).find { _1.type.to_s == "tool_use" && _1.name == tool }
      input = block&.input
      input = JSON.parse(input) if input.is_a?(String)
      input&.to_h&.deep_stringify_keys
    end

    def usage_of(response)
      usage_from(input: response.usage.input_tokens, output: response.usage.output_tokens,
                 cache_read: response.usage.cache_read_input_tokens, cache_write: response.usage.cache_creation_input_tokens)
    end
end
