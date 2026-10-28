# One route entry: a model plus the entry's overrides (section 4.2).
Ai::Spike::Route = Data.define(:model, :json_mode, :reasoning_effort) do
  def initialize(json_mode: nil, reasoning_effort: nil, **rest) = super

  def endpoint = model.endpoint
  def resolved_json_mode = json_mode || endpoint.json_mode
  def to_h = { endpoint: endpoint.name, model: model.name, json_mode: resolved_json_mode, reasoning_effort: }.compact
end
