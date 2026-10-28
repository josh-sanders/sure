# The OpenAI-compatible transport over RubyLLM: llama.cpp, Ollama, LM Studio,
# OpenRouter and OpenAI. Chat completions only; the Responses API stays
# outside the spike.
class Ai::Transport::Compatible < Ai::Transport::Base
  include Ai::Transport::JsonMode
  include Ai::Transport::RubyLlmAdapter

  def generate(request)
    instrument("generate", model: request.model, request: request.to_h.except(:model)) do
      generate_with_json_mode(request, json_mode: request.json_mode || endpoint.json_mode)
    end
  end

  def converse(request, &on_chunk)
    instrument("converse", model: request.model, request: request.to_h.except(:model), tools: request.tools.map(&:name)) do
      converse_with(chat_for(request.model), request, &on_chunk)
    end
  end

  def embed(texts, model:)
    instrument("embed", model:, request: { count: texts.size }) do
      embedding = mapping_errors { ruby_llm_context.embed(texts, model: model.name, provider: ruby_llm_provider, assume_model_exists: true) }
      vectors = texts.one? && embedding.vectors.first.is_a?(Numeric) ? [ embedding.vectors ] : embedding.vectors
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

    def chat_for(model) = ruby_llm_chat(model, provider: ruby_llm_provider, protocol: :chat_completions)

    # OpenRouter keeps its own provider: only it round-trips reasoning_details
    # (Gemini's thought signatures). Every other compatible server is :openai.
    def ruby_llm_provider = endpoint.preset == :openrouter ? :openrouter : :openai

    def configure_provider(config)
      base = Ai::Transport::Http.compatible_base(endpoint.base_url)
      if ruby_llm_provider == :openrouter
        config.openrouter_api_key = endpoint.api_key
        config.openrouter_api_base = base
      else
        config.openai_api_key = endpoint.api_key.presence || "none"   # RubyLLM requires a key; local servers ignore it
        config.openai_api_base = base
        config.openai_use_system_role = true   # otherwise system prompts go out as "developer"
      end
    end
end
