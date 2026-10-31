# Spike: one process per chat turn, Sure's own version of RubyLLM 2.2's
# "One Process at a Time" (rubyllm.com/next/durable-agents). A turn claims
# its chat with a conditional update of two columns on chats, claim_token
# and claimed_until, before it calls the model; renews the claim as it goes;
# and releases it at the end. Another job that finds the chat claimed does
# nothing. A claim that lapses (a dead worker) can be taken over, and the
# old turn's next renewal fails, so it stops before writing more.
#
# The columns are added by the spike's test inside its transaction; a real
# version would be a migration. Claims must be taken outside a transaction:
# an uncommitted claim is invisible to other processes.
module Ai::Spike::ChatClaim
  class Lost < StandardError; end

  singleton_class.attr_accessor :ttl
  self.ttl = 10.minutes

  module_function

  # Yields the token, or returns nil without yielding if another turn holds
  # the chat.
  def with_claim(chat)
    token = claim(chat) or return
    begin
      Thread.current[:ai_chat_claim] = [ chat.id, token ]
      yield token
    ensure
      Thread.current[:ai_chat_claim] = nil
      release(chat, token)
    end
  end

  def claim(chat)
    token = SecureRandom.uuid
    now = Time.current
    taken = Chat.where(id: chat.id).where("claimed_until IS NULL OR claimed_until < ?", now)
                .update_all(claim_token: token, claimed_until: now + ttl)
    token if taken == 1
  end

  # Extends this thread's claim; raises Lost if another turn took the chat
  # over after the claim lapsed.
  def renew!
    chat_id, token = Thread.current[:ai_chat_claim]
    return unless token

    kept = Chat.where(id: chat_id, claim_token: token).update_all(claimed_until: Time.current + ttl)
    raise Lost, "the chat's claim lapsed and another turn took it over" unless kept == 1
  end

  def release(chat, token) = Chat.where(id: chat.id, claim_token: token).update_all(claim_token: nil, claimed_until: nil)

  def running?(chat) = Chat.where(id: chat.id).where("claimed_until >= ?", Time.current).exists?
end
