# RubyLLM 2.2's own persistence, wired minimal for the spike. Sure's chats
# stay as they are in production; this exists only to measure the gem's
# claim machinery against Sure's chat-claim spike cases.
class SpikeChat < ApplicationRecord
  acts_as_chat messages: :spike_messages, message_class: "SpikeMessage", messages_foreign_key: "spike_chat_id"
end
