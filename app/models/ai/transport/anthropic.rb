# Anthropic's Messages API over RubyLLM. Structured output goes through one
# tool whose input_schema is the schema (section 7), not RubyLLM's
# with_schema, which sends Anthropic's native output_config instead.
class Ai::Transport::Anthropic < Ai::Transport::Base
  include Ai::Transport::RubyLlmAdapter

  def generate(request)
    instrument("generate", model: request.model, request: event_request(request)) do
      forced = Provider::Anthropic.forced_tool_choice_supported?(request.model.name)
      tool = request.schema_name
      chat = chat_for(request.model)
      chat.with_instructions(forced ? request.instructions : "#{request.instructions}\n\nReturn your answer by calling the #{tool} tool.")
      chat.with_tools(DeclaredTool.new(ToolSpec.new(name: tool, description: "Report the result.", schema: request.schema)))
      chat.with_tool_options(choice: forced ? tool.to_sym : :auto, calls: :one)
      chat.with_max_output_tokens(request.max_tokens || 4096)
      chat.add_message(role: :user, content: request.input, attachments: ruby_llm_attachments(request.attachments))

      message = mapping_errors { chat.generate }
      usage = usage_of(message)
      call = tool_call(message, tool)

      # #4513: a model that can't be forced may answer with text; ask once more.
      if call.nil? && !forced
        chat.add_message(role: :user, content: "You did not call the #{tool} tool. Call it now with the result; do not answer with text.")
        message = mapping_errors { chat.generate }
        usage += usage_of(message)
        call = tool_call(message, tool)
      end
      raise Ai::Error::InvalidOutput, "Model did not call #{tool} (#{message.finish_reason})" unless call

      Response.new(json: call.arguments, usage:, raw_id: raw_id(message))
    end
  end

  def converse(request, &on_chunk)
    instrument("converse", model: request.model, request: event_conversation(request), tools: request.tools.map(&:name)) do
      converse_with(chat_for(request.model), request, &on_chunk)
    end
  end

  private
    def tool_call(message, name) = message.tool_calls.to_h.values.find { _1.name == name }

    def chat_for(model) = ruby_llm_chat(model, provider: :anthropic)

    def configure_provider(config)
      config.anthropic_api_key = endpoint.api_key
      config.anthropic_api_base = endpoint.base_url
    end
end
