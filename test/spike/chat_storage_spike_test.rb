require "test_helper"
require "ruby_llm/test_helper"

# The stub never calls the network; the key only satisfies provider configuration.
RubyLLM.configure { |config| config.openai_api_key = "stub-not-a-real-key" }

# RubyLLM 2.2's own persistence, asked the four questions from Sure's
# chat-claim spike (docs/proposals/v0.8/ai-plumbing-redesign.md, part 5).
#
# The models exist only to answer those questions on the merged 2f stack;
# nothing here touches Sure's chats, messages or usages. Rubo-cop exempt: the
# gem's DSL is what's on trial.
class ChatStorageSpikeTest < ActiveSupport::TestCase
  include RubyLLM::TestHelper

  # Writes a row per tool call, so "did this turn's tool run twice?" has a
  # row to answer it.
  class SpikeWriteTool < RubyLLM::Tool
    def self.tool_name = "spike_write" # nested class; own the name RubyLLM derives
    description "Writes a record."

    parameters do
      string :body, description: "What to write"
    end

    def execute(body:)
      SpikeWrite.create!(body:)
      { ok: true, body: }
    end
  end

  # The same, but every call pauses for an approval first — the plan's
  # approval-clicked-twice case.
  class SpikeApprovalWriteTool < RubyLLM::Tool
    requires_approval
    def self.tool_name = "spike_approval_write"
    description "Writes a record, once an operator approves."

    parameters do
      string :body, description: "What to write"
    end

    def execute(body:)
      SpikeWrite.create!(body:)
      { ok: true, body: }
    end
  end

  setup do
    @model = RubyLLM::ActiveRecord::Model.find_or_create_by!(model_id: "stub-model", provider: "openai") do |m|
      m.name = "Stub Model"
      m.capabilities = []
    end
    @chat = SpikeChat.create!(model: @model)
    @chat.to_llm.with_tools(SpikeWriteTool.new, SpikeApprovalWriteTool.new)
  end

  teardown do
    RubyLLM::ActiveRecord::ToolCall.delete_all
    RubyLLM::ActiveRecord::Usage.delete_all
    RubyLLM::ActiveRecord::QueuedMessage.delete_all
    SpikeMessage.delete_all
    SpikeChat.delete_all
    SpikeWrite.delete_all
  end

  test "two jobs complete the same chat: one claims, the other returns without running" do
    stub_replies tool_call(:spike_write, body: "hello"), "done"

    chat = @chat
    chat.spike_messages.create!(role: "user", content: "write hello") # a queued turn

    # Another process is mid-turn: claim held with a future expiry.
    chat.update_columns(claim_token: "other-process", claimed_until: 10.minutes.from_now)
    chat.complete

    assert_equal 0, SpikeWrite.where(body: "hello").count, "the busy process ran the turn"
    assert_equal 1, chat.reload.spike_messages.count, "the busy process added a message"
    assert_nil chat.claim_token.presence&.then { nil } || nil, "claims are read from rows, not state"
  end

  test "the resumed run after a crashed one takes the claim and writes once" do
    stub_replies "recovered"

    chat = @chat
    chat.spike_messages.create!(role: "user", content: "still there?")
    # The dead process crashed mid-turn: token left, expiry passed.
    chat.update_columns(claim_token: "deadbeef", claimed_until: 1.minute.ago)

    chat.complete

    assert_equal "recovered", chat.reload.spike_messages.last.content
    assert_nil chat.reload.claim_token, "the claim is released when the turn finishes"
    assert_nil chat.reload.claimed_until, "the expiry is released with the claim"
  end

  test "a retry on an answered chat makes no call and no second tool run" do
    stub_replies tool_call(:spike_write, body: "once"), "done"

    chat = @chat
    chat.ask("write once")
    assert_equal 1, SpikeWrite.where(body: "once").count

    before = chat.reload.spike_messages.count
    chat.complete # Retry after completion: nothing pending; RubyLLM does not call the model again
    assert_equal before, chat.reload.spike_messages.count
    assert_equal 1, SpikeWrite.where(body: "once").count
  end

  test "an approval clicked twice is one decision and one tool run" do
    stub_replies tool_call(:spike_approval_write, body: "approved body"), "approved and done"

    chat = @chat
    chat.ask("write, after approval")

    call = RubyLLM::ActiveRecord::ToolCall.where(name: "spike_approval_write").sole
    assert_equal "pending", call.approval
    assert_equal 0, SpikeWrite.count

    # The double click: two approve calls on the same row, at the same time.
    threads = 2.times.map do
      Thread.new { SpikeChat.find(chat.id).approve(call) }
    end
    threads.map(&:value) # .value re-raises: a losing or crashed click must not hide

    assert_equal "approved", call.reload.approval
    chat.complete # run the approved tool

    assert_equal 1, SpikeWrite.where(body: "approved body").count
    assert_equal "approved and done", chat.reload.spike_messages.last.content
  end

  test "a queued message sent mid-turn lands at the next step, not in parallel" do
    stub_replies "first answer", "second answer"

    chat = @chat
    chat.ask("first")
    chat.queue "second, queued mid-turn", steer: false

    assert_equal 1, RubyLLM::ActiveRecord::QueuedMessage.count
    chat.complete

    assert_equal 0, RubyLLM::ActiveRecord::QueuedMessage.count
    contents = chat.reload.spike_messages.map(&:content)
    assert_includes contents, "second, queued mid-turn"
    assert_includes contents, "second answer"
  end

  test "the usage ledger writes rows for each attempt" do
    stub_replies tool_call(:spike_write, body: "ledger"), "done"

    chat = @chat
    chat.ask("write for the ledger")

    assert RubyLLM::ActiveRecord::Usage.exists?, "RubyLLM did not persist a usage row"
    rows = RubyLLM::ActiveRecord::Usage.where(chat_type: "SpikeChat", chat_id: chat.id)
    assert_operator rows.count, :>=, 1
  end

  test "a cancellation requested from another process stops the next turn" do
    stub_replies "answer"

    chat = @chat
    chat.spike_messages.create!(role: "user", content: "cancel me")
    SpikeChat.find(chat.id).cancel # another process asks the running or next turn to stop

    runner = SpikeChat.find(chat.id)
    assert_raises(RubyLLM::CancelledError) { runner.complete }
    assert_equal 0, SpikeWrite.count
  end

  test "two jobs racing to complete: exactly one turn runs" do
    stub_replies tool_call(:spike_write, body: "race"), "done"

    chat = @chat
    chat.spike_messages.create!(role: "user", content: "race me")

    threads = 2.times.map do
      Thread.new do
        other = SpikeChat.find(chat.id) # a second job, on the same row
        other.to_llm.with_tools(SpikeWriteTool.new, SpikeApprovalWriteTool.new)
        other.complete
      end
    end
    threads.map(&:value) # .value re-raises: a thread that died mid-turn fails loudly

    assert_equal 1, SpikeWrite.where(body: "race").count
  end
end
