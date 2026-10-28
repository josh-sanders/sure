# Section 10's Langfuse subscriber, cut down: one trace per .ai event, its
# generation holding the prompt, output, usage and error. The correlation id
# is the Langfuse session, so a job's calls group together.
class Ai::Instrumentation::LangfuseSubscriber
  def initialize(client: Rails.configuration.x.langfuse, environment: Rails.env)
    @client, @environment = client, environment
  end

  def call(event)
    return unless @client

    payload = event.payload
    prompt = plain(payload[:prompt])
    trace = @client.trace(name: "#{payload.dig(:prompt, :metadata, :feature) || "ai"}.#{event.name}", input: prompt,
                          session_id: payload[:correlation_id], environment: @environment,
                          metadata: payload.slice(:endpoint, :model, :tools, :error).compact)
    generation = trace&.generation(name: event.name, input: prompt, model: payload[:model])
    output = payload[:error] ? { error: payload[:error] } : plain(payload[:output])
    usage = payload[:usage]&.then { { input_tokens: _1.input_tokens + _1.cache_read_tokens.to_i, output_tokens: _1.output_tokens,
                                      prompt_tokens_details: { cached_tokens: _1.cache_read_tokens.to_i } } }
    generation&.end(output:, usage:, level: payload[:error] ? "ERROR" : nil)
    trace&.end(output:, level: payload[:error] ? "ERROR" : nil)
  end

  private
    # Value objects (Data) become plain hashes, all the way down.
    def plain(value)
      case value
      when Data then plain(value.to_h)
      when Hash then value.transform_values { plain(_1) }
      when Array then value.map { plain(_1) }
      else value
      end
    end
end
