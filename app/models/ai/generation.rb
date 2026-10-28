# Section 8.1's Ai::Generation, cut down to what the spike measures: render
# the prompt, call the route's transport, coerce the output. No router,
# sequencer, failover, batches or shadow runs.
class Ai::Generation
  class_attribute :feature_key, :prompt_key, :output_schema

  class << self
    def feature(key) = self.feature_key = key
    def prompt(key)  = self.prompt_key = key
    def schema(hash) = self.output_schema = hash
  end

  def prompt_locals = {}

  def call(route:, hand_written: false)
    request = Ai::Transport::Base::Request.new(
      model: route.model, instructions: rendered_prompt, input:, schema: output_schema, schema_name: feature_key.to_s,
      max_tokens: route.model.max_output_tokens, reasoning_effort: route.reasoning_effort, json_mode: route.json_mode,
      metadata: { feature: feature_key, route: route.to_h }
    )
    response = Ai::Transport.for(route.endpoint, hand_written:).generate(request)
    Result.new(value: Ai::Schema.coerce(response.json, output_schema), usage: response.usage, route:)
  end

  Result = Data.define(:value, :usage, :route)

  private
    def rendered_prompt
      template = Rails.root.join("app/prompts/#{prompt_key}.md.erb").read
      ERB.new(template, trim_mode: "<>").result_with_hash(prompt_locals).strip
    end
end
