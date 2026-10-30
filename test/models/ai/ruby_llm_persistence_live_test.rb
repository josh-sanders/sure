require_relative "spike_helper"

# Spike: RubyLLM's Rails persistence ("two application models": a chat and a
# message with acts_as_chat and acts_as_message), against the plan's choice
# to keep Sure's own Chat, UserMessage, AssistantMessage and ToolCall
# records (proposal 04, §20).
#
# RubyLLM's install templates are rendered for tables named spike_chats and
# spike_messages, with Sure's uuid keys, and run inside each test's
# transaction: Postgres rolls the DDL back, so the test database and
# db/schema.rb never change.
class Ai::RubyLlmPersistenceLiveTest < ActiveSupport::TestCase
  include AiSpikeHelper

  MODEL = "gemini-3.5-flash-lite".freeze
  TEMPLATES = Pathname(Gem.loaded_specs["ruby_llm"].full_gem_path).join("lib/generators/ruby_llm/install/templates")

  module SpikePersistence
    class Chat < ApplicationRecord
      self.table_name = "spike_chats"
      acts_as_chat messages: :messages, message_class: "Ai::RubyLlmPersistenceLiveTest::SpikePersistence::Message", messages_foreign_key: :spike_chat_id
    end

    class Message < ApplicationRecord
      self.table_name = "spike_messages"
      acts_as_message chat: :chat, chat_class: "Ai::RubyLlmPersistenceLiveTest::SpikePersistence::Chat", chat_foreign_key: :spike_chat_id
      has_many_attached :attachments
    end
  end

  # What RubyLLM's install generator would write, for these table names.
  class Template
    def initialize(path) = @erb = ERB.new(File.read(path), trim_mode: "-")
    def render = @erb.result(binding)
    def chat_table_name = "spike_chats"
    def message_table_name = "spike_messages"
    def reference_type = :uuid
    def migration_version = "[#{Rails::VERSION::MAJOR}.#{Rails::VERSION::MINOR}]"
    def create_migration_class_name(table) = "SpikeCreate#{table.camelize}"
    def postgresql? = true
    def usage_operations_sql = RubyLLM::Accounting::Usage::Entry::OPERATIONS.map { "'#{_1}'" }.join(", ")
    def usage_statuses_sql = RubyLLM::Accounting::Usage::Entry::STATUSES.map { "'#{_1}'" }.join(", ")
  end

  setup do
    ActiveRecord::Migration.suppress_messages do
      %w[create_ruby_llm_records_migration create_chats_migration create_messages_migration].each do |name|
        source = Template.new(TEMPLATES.join("#{name}.rb.tt")).render
        klass = source[/class (\w+)/, 1]
        self.class.const_get(klass) rescue self.class.class_eval(source) # rubocop:disable Style/RescueModifier
        self.class.const_get(klass).new.migrate(:up)
      end
    end
    [ SpikePersistence::Chat, SpikePersistence::Message, RubyLLM::ActiveRecord::Usage ].each(&:reset_column_information)
    @tables = %w[ruby_llm_models ruby_llm_tool_calls ruby_llm_usages ruby_llm_batches ruby_llm_provider_files ruby_llm_mcp_credentials spike_chats spike_messages]
  end

  def context = Ai::Transport.for(Ai::Spike::Presets.gemini_native(api_key: ENV.fetch("SPIKE_GEMINI_API_KEY", "gemini-key"), max_retries: 0)).send(:ruby_llm_context)

  test "the install creates eight tables, and Sure's Chat and Message would need RubyLLM's columns" do
    assert @tables.all? { ActiveRecord::Base.connection.table_exists?(_1) }
    missing = SpikePersistence::Message.column_names - ::Message.column_names
    assert_includes missing, "role"
    assert_includes missing, "thinking_signature"
    assert_includes SpikePersistence::Chat.column_names, "ruby_llm_model_id"
    assert_not_includes ::Chat.column_names, "ruby_llm_model_id"
    puts "\n  messages need: #{missing.sort.inspect}" if ENV["SPIKE_PRINT"]
  end

  test "a persisted chat continues from the database, and each message knows its producer (live)" do
    RubyLLM::ActiveRecord::Model.save_to_database
    with_spike_cassette("features/persistence") do
      chat = SpikePersistence::Chat.create!(model: MODEL, provider: :gemini).with_context(context)
      chat.ask("My favourite number is 42. Just say OK.")
      @reloaded = SpikePersistence::Chat.find(chat.id).with_context(context)
      @answer = @reloaded.ask("What is my favourite number?")
    end

    assert_match "42", @answer.content
    assert_equal %w[user assistant user assistant], @reloaded.messages.order(:created_at).map(&:role)
    usages = RubyLLM::ActiveRecord::Usage.all
    assert_equal [ [ "gemini", MODEL ] ] * 2, usages.map { [ _1.provider, _1.model ] }
    assert_equal MODEL, @reloaded.messages.where(role: "assistant").last.model, "the producer, from the usage ledger"
  end

  # The note says not to create ruby_llm_usages: once it exists, RubyLLM
  # records every call, persisted chat or not. This replays a recording of
  # a plain chat (no acts_as_chat) and counts the rows it leaves.
  EXPECTED_PLAIN_CHAT_ROWS = 1

  test "once ruby_llm_usages exists, a plain RubyLLM chat writes usage rows too" do
    skip "replay only: it reuses features/streaming" if recording?

    with_spike_cassette("features/streaming") do
      endpoint = Ai::Spike::Presets.gemini(api_key: ENV.fetch("SPIKE_GEMINI_API_KEY", "gemini-key"), max_retries: 0)
      Ai::Transport.for(endpoint).send(:chat_for, Ai::Spike::Model.new(endpoint:, name: MODEL)).ask("Count from 1 to 20, comma separated.") { nil }
    end

    @rows = RubyLLM::ActiveRecord::Usage.count
    puts "\n  usage rows after one plain chat: #{@rows}" if ENV["SPIKE_PRINT"]
    assert_equal EXPECTED_PLAIN_CHAT_ROWS, @rows if defined?(EXPECTED_PLAIN_CHAT_ROWS)
  end
end
