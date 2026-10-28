require_relative "spike_helper"

# Sure owns the tool loop: the transport calls RubyLLM's Chat#generate, which
# returns tool calls without running them, and Ai::Conversation runs them
# through Assistant::FunctionToolCaller.
class Ai::ConverseTest < ActiveSupport::TestCase
  include AiSpikeHelper

  setup do
    @user = users(:family_admin)
    @functions = [ Assistant::Function::GetAccounts.new(@user) ]
  end

  def conversation(route = llama_route, max_tool_rounds: 4, turn_timeout: 600)
    Ai::Conversation.new(route:, functions: @functions, max_tool_rounds:, turn_timeout:,
                         instructions: "You are a finance assistant. Use tools to look up the user's data. Be brief.")
  end

  def question = [ Ai::Transport::Base::Message.new(role: :user, content: "How many accounts do I have? Look them up.") ]

  test "llama.cpp streams a tool call, Sure runs it, the model answers on round two" do
    RubyLLM::Tool.any_instance.expects(:call).never
    chunks = []
    events = capture_ai_events do
      with_spike_cassette("llama_cpp/converse_tool_round") do
        @result = conversation.respond(question) { chunks << _1 }
      end
    end

    assert_equal 2, @result.rounds
    assistant, tool = @result.messages[1], @result.messages[2]
    assert_equal [ "get_accounts" ], assistant.tool_calls.map(&:name)
    assert_equal :tool, tool.role
    assert_equal assistant.tool_calls.first.id, tool.tool_call_id
    assert_match "accounts", tool.content
    assert_operator chunks.size, :>, 1, "the answer streams"
    assert @result.text.present?

    assert_equal %w[converse.ai converse.ai], events.map(&:name), "one event per round"
    assert_equal [ 1, 2 ], events.map { _1.payload[:prompt][:metadata][:round] }
    assert_equal [ "get_accounts" ], events.first.payload[:tools]
    assert events.all? { _1.payload[:usage].output_tokens.positive? }

    second_request = request_bodies(%r{llama-cpp.test|8180}).last
    assert_equal %w[system user assistant tool], second_request["messages"].map { _1["role"] }
    assert second_request["stream"]
  end

  test "the last round declares the tools with tool_choice none, so the model must answer" do
    with_spike_cassette("llama_cpp/converse_final_round") do
      @result = conversation(max_tool_rounds: 1).respond(question)
    end

    assert_equal 1, @result.rounds
    assert_empty @result.messages.last.tool_calls
    body = request_bodies(%r{llama-cpp.test|8180}).last
    assert_equal "none", body["tool_choice"]
    assert_equal [ "get_accounts" ], body["tools"].map { _1.dig("function", "name") }
  end

  test "the turn deadline stops a stream mid-flight as Ai::Error::Timeout" do
    convo = conversation(turn_timeout: 10)
    convo.stubs(:now).returns(0, 0, 0, 0, 100)   # deadline at 10; the fourth chunk check is past it
    chunks = []

    with_spike_cassette("llama_cpp/converse_final_round") do
      assert_raises(Ai::Error::Timeout) { convo.respond(question) { chunks << _1 } }
    end
    assert_operator chunks.size, :>=, 1
  end
end
