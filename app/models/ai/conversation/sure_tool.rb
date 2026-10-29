# Spike: an Assistant::Function as a RubyLLM::Tool, so RubyLLM's run_tools
# can run it. Assistant::FunctionToolCaller still calls the function, so a
# failure still comes back as Sure's data (no SQL in a not-found, the retry
# hints), not as an exception that ends the turn.
class Ai::Conversation::SureTool < RubyLLM::Tool
  # Nothing marks which tools write (section 3 of the architecture review);
  # the spike goes by name.
  READ_ONLY = /\A(get|list|search|preview)_/

  # approval: (tool_call) -> true, false or nil (undecided). Given, every
  # write tool waits for a decision before it runs.
  def self.for(function, approval: nil)
    return new(function) unless approval && !function.name.match?(READ_ONLY)

    Class.new(self) { requires_approval { |tool_call| approval.call(tool_call) } }.new(function)
  end

  def initialize(function)
    @function = function
    super()
  end

  def name = @function.name
  def description = @function.description
  def parameters_schema = @function.params_schema

  def execute(**arguments)
    request = Provider::LlmConcept::ChatFunctionRequest.new(id: nil, call_id: nil, function_name: name, function_args: arguments.to_json)
    Assistant::FunctionToolCaller.new([ @function ]).fulfill_requests([ request ]).sole.function_result
  end
end
