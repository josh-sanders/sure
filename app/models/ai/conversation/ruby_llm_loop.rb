# Spike: section 8.4's turn with RubyLLM running the tools. Sure still
# drives the loop one move at a time (Chat#run_tools, then Chat#generate
# through the transport), so its bounds hold: at most max_tool_rounds model
# calls, the last with tool_choice none, and one deadline for the turn,
# checked while streaming and before each tool. Compatible transport only.
#
# With approval:, write tools wait for a decision. The turn then ends
# :awaiting_approval with the history so far; Sure stores it, and calling
# respond again with that history, once the decision is recorded, resumes
# the turn. A history whose last tool calls have no results (a worker that
# died mid-round) resumes the same way.
class Ai::Conversation::RubyLlmLoop < Ai::Conversation
  Result = Data.define(:text, :rounds, :usage, :messages, :status, :pending)

  # concurrency: nil (one tool after another) or :threads.
  # cancelled: checked while streaming and before each tool, as section 12's
  # -> { message.reload.cancelled? }.
  def initialize(concurrency: nil, approval: nil, cancelled: -> { false }, **)
    super(**)
    @concurrency, @approval, @cancelled = concurrency, approval, cancelled
  end

  def respond(messages, &on_text)
    deadline = now + @turn_timeout
    chat = transport.tool_chat(request(messages, final: false, round: 1), tools: @functions.map { Ai::Conversation::SureTool.for(_1, approval: @approval) })
    chat.with_tool_options(concurrency: @concurrency) if @concurrency
    chat.before_tool_call { check!(deadline) }
    usage = Ai::Usage.empty

    1.upto(@max_tool_rounds) do |round|
      chat.run_tools   # this turn's pending calls, or a resumed turn's; nothing on the first round
      return result(chat, round - 1, usage, :awaiting_approval) if chat.waiting?

      check!(deadline)
      final = round == @max_tool_rounds
      turn = transport.tool_round(chat, request([], final:, round:)) do |text|
        check!(deadline)
        on_text&.call(text)
      end
      usage += turn.usage
      return result(chat, round, usage, :complete) if turn.tool_calls.empty? || final
    end
  end

  private
    def check!(deadline)
      raise Ai::Error::Cancelled, "the user cancelled the turn" if @cancelled.call

      super
    end

    def result(chat, rounds, usage, status)
      messages = transport.history(chat)
      Result.new(text: messages.last&.content.to_s, rounds:, usage:, messages:, status:, pending: chat.pending_approvals)
    end
end
