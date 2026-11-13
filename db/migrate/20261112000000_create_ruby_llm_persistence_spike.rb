# RubyLLM 2.2 chat persistence, minimized to what the claim semantics need.
# Shapes taken verbatim from RubyLLM's own install templates.
class CreateRubyLlmPersistenceSpike < ActiveRecord::Migration[8.1]
  def change
    create_table :ruby_llm_models, id: :uuid, default: -> { "gen_random_uuid()" }, force: false do |t|
      t.string :model_id, null: false
      t.string :name, null: false
      t.string :provider, null: false
      t.string :family
      t.datetime :model_created_at
      t.integer :context_window
      t.integer :max_output_tokens
      t.date :knowledge_cutoff
      t.datetime :unlisted_at
      t.jsonb :modalities, default: {}
      t.jsonb :capabilities, default: []
      t.jsonb :pricing, default: {}
      t.jsonb :metadata, default: {}
      t.timestamps

      t.index [ :provider, :model_id ], unique: true
      t.index :provider
      t.index :family
      t.index :capabilities, using: :gin
      t.index :modalities, using: :gin
    end

    create_table :spike_chats, id: :uuid, default: -> { "gen_random_uuid()" }, force: false do |t|
      t.references :ruby_llm_model, null: false, foreign_key: { to_table: :ruby_llm_models }, type: :uuid
      t.boolean :cancelled, null: false, default: false
      t.string :claim_token
      t.datetime :claimed_until
      t.timestamps

      t.index :claimed_until, where: "claim_token IS NOT NULL"
    end

    create_table :spike_messages, id: :uuid, default: -> { "gen_random_uuid()" }, force: false do |t|
      t.references :spike_chat, null: false, foreign_key: { to_table: :spike_chats }, type: :uuid
      t.string :role, null: false
      t.text :content
      t.boolean :cache_until_here, null: false, default: false
      t.string :cache_ttl
      t.text :thinking_text
      t.text :thinking_signature
      t.jsonb :citations
      t.jsonb :server_tool_calls
      t.jsonb :raw_content
      t.jsonb :raw_reasoning
      t.string :phase
      t.text :continuation
      t.string :finish_reason
      t.timestamps
    end

    create_table :ruby_llm_tool_calls, id: :uuid, default: -> { "gen_random_uuid()" }, force: false do |t|
      t.references :message, polymorphic: true, null: false, type: :uuid, index: false
      t.references :result, polymorphic: true, type: :uuid, index: false
      t.string :tool_call_id, null: false
      t.string :provider_call_id
      t.string :namespace
      t.string :name, null: false
      t.text :thought_signature
      t.string :approval
      t.boolean :remote, default: false, null: false
      t.datetime :claimed_until
      t.jsonb :arguments, default: {}
      t.jsonb :mcp_state
      t.jsonb :mcp_result
      t.timestamps

      t.index [ :message_type, :message_id ]
      t.index [ :result_type, :result_id ]
      t.index :tool_call_id, unique: true
      t.index :name
    end

    create_table :ruby_llm_usages, id: :uuid, default: -> { "gen_random_uuid()" }, force: false do |t|
      t.references :chat, polymorphic: true, type: :uuid, index: false
      t.references :message, polymorphic: true, type: :uuid, index: false
      t.references :owner, polymorphic: true, type: :uuid, index: false
      t.string :operation, null: false
      t.string :provider, null: false
      t.string :model, null: false
      t.string :status, null: false
      t.integer :input_tokens
      t.integer :output_tokens
      t.integer :cache_read_tokens
      t.integer :cache_write_tokens
      t.integer :thinking_tokens
      t.integer :characters
      t.jsonb :server_tool_use
      t.decimal :input_cost, precision: 16, scale: 10
      t.decimal :output_cost, precision: 16, scale: 10
      t.decimal :cache_read_cost, precision: 16, scale: 10
      t.decimal :cache_write_cost, precision: 16, scale: 10
      t.decimal :thinking_cost, precision: 16, scale: 10
      t.decimal :characters_cost, precision: 16, scale: 10
      t.decimal :total_cost, precision: 16, scale: 10
      t.string :workflow_id
      t.string :workflow_name
      t.string :workflow_step_id
      t.string :workflow_step_name
      t.timestamps

      t.index [ :chat_type, :chat_id ]
      t.index [ :message_type, :message_id ]
      t.index [ :owner_type, :owner_id ]
      t.index :status
      t.index :workflow_id
      t.check_constraint "operation IN ('chat','embedding','judgment','audio_transcription','speech','rerank','ocr','moderation','video','batch')", name: "ruby_llm_usages_operation_check"
      t.check_constraint "status IN ('succeeded','failed','cancelled')", name: "ruby_llm_usages_status_check"
    end

    create_table :ruby_llm_queued_messages, id: :uuid, default: -> { "gen_random_uuid()" }, force: false do |t|
      t.references :chat, polymorphic: true, null: false, type: :uuid, index: false
      t.references :sender, polymorphic: true, type: :uuid, index: false
      t.text :content
      t.boolean :steer, default: true, null: false
      t.timestamps

      t.index [ :chat_type, :chat_id ]
      t.index [ :sender_type, :sender_id ]
    end
  end
end
