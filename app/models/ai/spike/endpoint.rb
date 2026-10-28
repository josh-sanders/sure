# Stands in for AiEndpoint/AiModel/AiRoute (sections 4.2-4.3) during the
# spike: a hard-coded struct built from the spike's own ENV.
Ai::Spike::Endpoint = Data.define(
  :name, :protocol, :preset, :base_url, :api_key, :timeout_seconds, :max_retries, :json_mode, :extra_headers, :extra_body, :responses_api, :agent, :agent_settings
) do
  def initialize(timeout_seconds: 300, max_retries: 0, json_mode: "auto", extra_headers: {}, extra_body: {}, responses_api: false, agent: false, agent_settings: {}, **rest) = super
end
