# The transport interface (section 7). Everything above a transport sees these
# value objects and Ai::Error, never a client library's types.
class Ai::Transport::Base
  # json_mode isn't in section 7's Request, but the route entry's override
  # has to reach the transport somehow.
  Request = Data.define(:model, :instructions, :input, :schema, :schema_name, :max_tokens, :reasoning_effort,
                        :json_mode, :attachments, :metadata) do
    def initialize(schema: nil, schema_name: "result", max_tokens: nil, reasoning_effort: nil, json_mode: nil,
                   attachments: [], metadata: {}, **rest) = super
  end

  Response = Data.define(:json, :usage, :raw_id)

  # converse: section 7 gives only `converse(request, &on_chunk)`. A chat
  # round needs the history (with tool results) and the tools, and returns
  # the model's tool calls rather than running them (section 5.5).
  Message = Data.define(:role, :content, :tool_calls, :tool_call_id, :provider_state) do
    def initialize(content: nil, tool_calls: [], tool_call_id: nil, provider_state: nil, **rest) = super
  end
  ToolCall = Data.define(:id, :name, :arguments)
  ToolSpec = Data.define(:name, :description, :schema)
  ConverseRequest = Data.define(:model, :instructions, :messages, :tools, :max_tokens, :reasoning_effort, :metadata) do
    def initialize(tools: [], max_tokens: nil, reasoning_effort: nil, metadata: {}, **rest) = super
  end
  # provider_state is opaque: whatever the transport needs back on the next
  # round (Gemini's reasoning_details, Anthropic's thinking signatures).
  Turn = Data.define(:text, :tool_calls, :usage, :raw_id, :finish_reason, :provider_state)

  attr_reader :endpoint

  def initialize(endpoint)
    @endpoint = endpoint
  end

  def generate(request)            = raise NotImplementedError
  def converse(request, &on_chunk) = raise NotImplementedError
  def judge(state:, questions:)    = raise NotImplementedError
  def embed(texts, model:)         = raise NotImplementedError

  private
    # One .ai event per wire call (section 10). Subscribers get the prompt,
    # the output, the usage and the error class; tool rounds are one event each.
    def instrument(name, model:, request:, **payload)
      event = { transport: self.class.name, endpoint: endpoint.name, model: model.name, prompt: request,
                correlation_id: Ai::Correlation.current, **payload }
      ActiveSupport::Notifications.instrument("#{name}.ai", event) do
        result = yield
        event[:output] = result.respond_to?(:json) ? result.json : result
        event[:usage] = result.usage if result.respond_to?(:usage)
        result
      rescue Ai::Error::Base => e
        event[:error] = e.class.name
        raise
      end
    end

    def usage_from(input:, output:, cache_read: 0, cache_write: 0)
      Ai::Usage.new(input_tokens: input.to_i, output_tokens: output.to_i, cache_read_tokens: cache_read.to_i,
                    cache_write_tokens: cache_write.to_i, cost: nil)
    end
end
