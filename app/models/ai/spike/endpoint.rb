# Stands in for AiEndpoint/AiModel/AiRoute (sections 4.2-4.3) during the
# spike: a hard-coded struct built from the spike's own ENV.
Ai::Spike::Endpoint = Data.define(
  :name, :protocol, :preset, :base_url, :api_key, :timeout_seconds, :max_retries, :json_mode, :extra_headers, :extra_body, :responses_api, :agent, :agent_settings, :location
) do
  def initialize(timeout_seconds: 300, max_retries: 0, json_mode: "auto", extra_headers: {}, extra_body: {}, responses_api: false, agent: false, agent_settings: {}, location: nil, **rest) = super

  # Section 4.2's location column; the spike's presets imply it.
  def local? = (location || (%i[llama_cpp ollama lmstudio].include?(preset) ? :local : :cloud)) == :local
end
