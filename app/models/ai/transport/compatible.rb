# The OpenAI-compatible transport over RubyLLM: llama.cpp, Ollama, LM Studio,
# OpenRouter and OpenAI. An endpoint with responses_api uses RubyLLM's
# Responses protocol, which is stateless (store: false): no previous_response_id.
class Ai::Transport::Compatible < Ai::Transport::Base
  include Ai::Transport::JsonMode
  include Ai::Transport::RubyLlmAdapter

  def generate(request)
    instrument("generate", model: request.model, request: request.to_h.except(:model)) do
      # The Responses API always takes a strict schema (section 7).
      generate_with_json_mode(request, json_mode: endpoint.responses_api ? "strict" : request.json_mode || endpoint.json_mode)
    end
  end

  def converse(request, &on_chunk)
    instrument("converse", model: request.model, request: request.to_h.except(:model), tools: request.tools.map(&:name)) do
      converse_with(converse_chat(request), request, &on_chunk)
    end
  end

  # Spike (Ai::Conversation::RubyLlmLoop): a chat holding the history and
  # the tools RubyLLM runs itself, advanced one model call at a time by
  # tool_round, each a converse.ai event as in Sure's own loop.
  def tool_chat(request, tools:)
    converse_chat(request).tap do |chat|
      prepare_converse(chat, request)
      chat.with_tools(*tools)
    end
  end

  def tool_round(chat, request, &on_chunk)
    instrument("converse", model: request.model, request: request.to_h.except(:model, :messages, :tools).merge(messages: history(chat)),
                           tools: chat.tools.keys.map(&:to_s)) do
      chat.with_tool_options(choice: request.tool_choice)
      generate_turn(chat, &on_chunk)
    end
  end

  def history(chat) = sure_messages(chat.messages)

  def embed(texts, model:)
    instrument("embed", model:, request: { count: texts.size }) do
      embedding = mapping_errors { ruby_llm_context.embed(texts, model: model.name, provider: ruby_llm_provider, assume_model_exists: true) }
      vectors = texts.one? && embedding.vectors.first.is_a?(Numeric) ? [ embedding.vectors ] : embedding.vectors
      # 2.1.1 doesn't check the row count (fixed upstream after it, #1269).
      raise Ai::Error::InvalidOutput, "expected #{texts.size} vectors, got #{vectors.size}" unless vectors.size == texts.size
      { vectors:, usage: usage_from(input: embedding.tokens.input, output: 0) }
    end
  end

  private
    def complete_json(request, mode:, effort:)
      chat = chat_for(request.model)
      chat.with_instructions(mode == "none" ? request.instructions + schema_example(request.schema) : request.instructions)
      chat.with_max_output_tokens(request.max_tokens) if request.max_tokens
      chat.with_schema(name: request.schema_name, schema: request.schema, strict: true) if mode == "strict"
      chat.with_provider_options(endpoint.extra_body.merge(mode == "json_object" ? { response_format: { type: "json_object" } } : {}))
      chat.with_thinking(effort:) if effort
      chat.add_message(role: :user, content: request.input)

      message = mapping_errors { chat.generate }
      [ message.content, usage_of(message), raw_id(message) ]
    end

    # The external assistant (section 5.6): its routing headers from agent_settings.
    def agent_headers
      { "X-Agent-Id" => endpoint.agent_settings[:agent_id], "X-Session-Key" => endpoint.agent_settings[:session_key] }.compact
    end

    def converse_chat(request)
      chat = chat_for(request.model)
      chat.with_thinking(effort: request.reasoning_effort) if request.reasoning_effort && !endpoint.agent   # Anthropic ignores it (section 7)
      chat.with_headers(Ai::Transport::Http.headers(endpoint).merge(agent_headers)) if endpoint.agent
      chat
    end

    def chat_for(model) =ruby_llm_chat(model, provider: ruby_llm_provider, protocol: endpoint.responses_api ? :responses : :chat_completions)

    # OpenRouter keeps its own provider: only it round-trips reasoning_details
    # (Gemini's thought signatures). Every other compatible server is :openai.
    def ruby_llm_provider = endpoint.preset == :openrouter ? :openrouter : :openai

    def configure_provider(config)
      base = Ai::Transport::Http.compatible_base(endpoint.base_url)
      config.openai_use_system_role = true   # both providers send system prompts as "developer" otherwise
      if ruby_llm_provider == :openrouter
        config.openrouter_api_key = endpoint.api_key
        config.openrouter_api_base = base
        config.openrouter_app_name = "Sure"   # RubyLLM otherwise sends "RubyLLM" and https://rubyllm.com
        config.openrouter_app_url = "https://sure.am"
      else
        config.openai_api_key = endpoint.api_key.presence || "none"   # RubyLLM requires a key; local servers ignore it
        config.openai_api_base = base
      end
    end
end
