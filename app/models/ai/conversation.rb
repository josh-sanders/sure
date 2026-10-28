# Section 8.4's Ai::Conversation, cut down to the tool loop: Sure owns it,
# whatever the transport. Two bounds (section 5.5): at most max_tool_rounds
# model calls, the last forbidding tools, and one deadline for the whole turn.
class Ai::Conversation
  Result = Data.define(:text, :rounds, :usage, :messages)
  T = Ai::Transport::Base

  def initialize(route:, functions:, max_tool_rounds:, turn_timeout:, instructions:)
    @route, @functions, @max_tool_rounds, @turn_timeout, @instructions = route, functions, max_tool_rounds, turn_timeout, instructions
  end

  def respond(messages, &on_text)
    deadline = now + @turn_timeout
    history = messages.dup
    usage = Ai::Usage.empty

    1.upto(@max_tool_rounds) do |round|
      check!(deadline)
      final = round == @max_tool_rounds
      turn = transport.converse(request(history, final:, round:)) do |text|
        check!(deadline)   # a stream that keeps trickling never trips a read timeout
        on_text&.call(text)
      end
      usage += turn.usage
      history << T::Message.new(role: :assistant, content: turn.text, tool_calls: turn.tool_calls, provider_state: turn.provider_state)
      return Result.new(text: turn.text, rounds: round, usage:, messages: history) if turn.tool_calls.empty? || final

      run_tools(turn.tool_calls).each { history << _1 }
    end
  end

  private
    def transport = @transport ||= Ai::Transport.for(@route.endpoint)

    # The final round still declares the tools, with tool_choice none: Anthropic
    # rejects a history holding tool_use blocks when the request has no tools.
    def request(history, final:, round:)
      T::ConverseRequest.new(
        model: @route.model, instructions: @instructions, messages: history,
        tools: @functions.map { T::ToolSpec.new(name: _1.name, description: _1.description, schema: _1.params_schema) },
        tool_choice: final ? :none : nil, max_tokens: @route.model.max_output_tokens,
        reasoning_effort: @route.reasoning_effort, metadata: { feature: :chat, round: }
      )
    end

    def run_tools(tool_calls)
      requests = tool_calls.map do |call|
        Provider::LlmConcept::ChatFunctionRequest.new(id: call.id, call_id: call.id, function_name: call.name,
                                                      function_args: call.arguments.to_json)
      end
      Assistant::FunctionToolCaller.new(@functions).fulfill_requests(requests).map do |tool_call|
        T::Message.new(role: :tool, content: tool_call.function_result.to_json, tool_call_id: tool_call.provider_call_id)
      end
    end

    def check!(deadline)
      raise Ai::Error::Timeout, "turn exceeded #{@turn_timeout}s" if now > deadline
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
