# The spike's endpoints, from its own ENV only. Missing values mean the
# server isn't set up; tests then replay cassettes against the placeholder URL.
module Ai::Spike::Presets
  PLACEHOLDERS = {
    llama_cpp: "http://llama-cpp.test/v1",
    llama_cpp_embed: "http://llama-cpp-embed.test/v1",
    ollama: "http://ollama.test",
    lmstudio: "http://lmstudio.test",
    openrouter: "https://openrouter.ai/api/v1",
    gemini: "https://generativelanguage.googleapis.com/v1beta/openai",
    anthropic: "https://api.anthropic.com",
    openai: "https://api.openai.com/v1",
    openclaw: "http://openclaw.test:18789/v1/chat/completions"
  }.freeze

  module_function

  def url(key, env) = ENV[env].presence || PLACEHOLDERS.fetch(key)

  def llama_cpp(**overrides)
    Ai::Spike::Endpoint.new(
      name: "llama.cpp", protocol: :compatible, preset: :llama_cpp,
      base_url: url(:llama_cpp, "SPIKE_LLAMA_CPP_URL"), api_key: ENV["SPIKE_LLAMA_CPP_API_KEY"],
      timeout_seconds: 300, json_mode: "auto", **overrides
    )
  end

  def llama_cpp_embed(**overrides)
    Ai::Spike::Endpoint.new(
      name: "llama.cpp embeddings", protocol: :compatible, preset: :llama_cpp,
      base_url: url(:llama_cpp_embed, "SPIKE_LLAMA_CPP_EMBED_URL"), api_key: ENV["SPIKE_LLAMA_CPP_API_KEY"],
      timeout_seconds: 60, **overrides
    )
  end

  def ollama(**overrides)
    Ai::Spike::Endpoint.new(name: "Ollama", protocol: :compatible, preset: :ollama,
                            base_url: url(:ollama, "SPIKE_OLLAMA_URL"), api_key: nil, **overrides)
  end

  def lmstudio(**overrides)
    Ai::Spike::Endpoint.new(name: "LM Studio", protocol: :compatible, preset: :lmstudio,
                            base_url: url(:lmstudio, "SPIKE_LMSTUDIO_URL"), api_key: nil, **overrides)
  end

  # The external assistant (section 5.6): an agent gateway such as OpenClaw.
  def openclaw(**overrides)
    Ai::Spike::Endpoint.new(name: "OpenClaw", protocol: :compatible, preset: :agent,
                            base_url: url(:openclaw, "SPIKE_OPENCLAW_URL"), api_key: ENV["SPIKE_OPENCLAW_TOKEN"] || "spike-token",
                            agent: true, agent_settings: { agent_id: "main", session_key: "agent:main:main" },
                            timeout_seconds: 600, **overrides)
  end

  def openrouter(**overrides)
    Ai::Spike::Endpoint.new(name: "OpenRouter", protocol: :compatible, preset: :openrouter,
                            base_url: PLACEHOLDERS[:openrouter], api_key: ENV["SPIKE_OPENROUTER_API_KEY"],
                            json_mode: "strict", timeout_seconds: 120, **overrides)
  end

  # Gemini through Google's OpenAI-compatible API (section 4.2).
  def gemini(**overrides)
    Ai::Spike::Endpoint.new(name: "Gemini", protocol: :compatible, preset: :gemini,
                            base_url: PLACEHOLDERS[:gemini], api_key: ENV["SPIKE_GEMINI_API_KEY"],
                            json_mode: "auto", timeout_seconds: 120, **overrides)
  end

  # OpenAI direct (section 4.2): the preset sets responses_api, stateless.
  def openai(**overrides)
    Ai::Spike::Endpoint.new(name: "OpenAI", protocol: :compatible, preset: :openai,
                            base_url: PLACEHOLDERS[:openai], api_key: ENV["SPIKE_OPENAI_API_KEY"],
                            json_mode: "strict", responses_api: true, timeout_seconds: 120, **overrides)
  end

  def anthropic(**overrides)
    Ai::Spike::Endpoint.new(name: "Anthropic", protocol: :anthropic, preset: :anthropic,
                            base_url: PLACEHOLDERS[:anthropic], api_key: ENV["SPIKE_ANTHROPIC_API_KEY"],
                            json_mode: "strict", timeout_seconds: 120, **overrides)
  end
end
