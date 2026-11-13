class SpikeMessage < ApplicationRecord
  acts_as_message chat: :spike_chat, chat_class: "SpikeChat", chat_foreign_key: "spike_chat_id"
end
