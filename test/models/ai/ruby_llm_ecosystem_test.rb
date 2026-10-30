require_relative "spike_helper"
require_relative "statement_scoring"

# Spike: RubyLLM ecosystem gems that install beside 2.1.1 (Gemfile, test
# group, require: false), each against the plan decision it bears on. These
# run offline: test adapters, recorded responses, or no model at all.
class Ai::RubyLlmEcosystemTest < ActiveSupport::TestCase
  include AiSpikeHelper
  include StatementScoring

  # -- ruby_llm-contract: runtime validation and model escalation --------------
  #
  # Plan: ExtractBankStatement plus the JSON-mode chain, and the answer-free
  # checks the PDF spike built (reconciles, dates anchored). For contract:
  # validate rules and escalation to a stronger model are declared in the
  # step, with a trace of every attempt and its cost. Against: a second
  # orchestration layer beside Sure's router, which already owns failover.
  test "ruby_llm-contract: a failed reconciliation escalates to the next model" do
    require "ruby_llm/contract"
    RubyLLM::Contract.configure { |c| c.default_model = "lightning" }

    step = Class.new(RubyLLM::Contract::Step::Base) do
      prompt "Extract every transaction from this bank statement as JSON.\n\n{input}"
      output_schema do
        number :opening_balance
        number :closing_balance
        array :transactions do
          object do
            string :date
            number :amount
          end
        end
      end
      validate("opening balance plus transactions makes the closing balance") do |o, _|
        (o[:opening_balance] + o[:transactions].sum { _1[:amount] }).round(2) == o[:closing_balance].round(2)
      end
      retry_policy { escalate "lightning", "gemini-3.5-flash-lite" }
    end

    # Lightning's real wrong extraction of BAC (statements/openrouter_lightning_bac_ocr_text),
    # then the right one Gemini gave (statements/gemini_bac_ocr_text).
    wrong = { opening_balance: 40_000.0, closing_balance: 44_079.83,
              transactions: [ { date: "2019-02-01", amount: -40_000.0 }, { date: "2019-02-28", amount: -987.33 } ] }
    right = { opening_balance: 40_000.0, closing_balance: 44_079.83,
              transactions: STATEMENTS["bac_ocr"][:transactions].map { |date, amount| { date: "2019-#{date}", amount: } } }
    result = step.run("…statement text…", context: { adapter: RubyLLM::Contract::Adapters::Test.new(responses: [ wrong, right ]) })

    assert_equal :ok, result.status
    attempts = result.trace[:attempts]
    assert_equal [ [ "lightning", :validation_failed ], [ "gemini-3.5-flash-lite", :ok ] ], attempts.map { [ _1[:model], _1[:status] ] }
  end

  # -- ruby_llm-test and ruby_llm-instructor: in their own process ---------------
  #
  # ruby_llm-instructor: a Ruby class as the response model, validated, with
  # the validation error fed back for another attempt. Its 0.2.0 installs
  # beside 2.1.1 but reads 1.x's parsed content, so it fails on every reply.
  #
  # Plan: tests replay recorded HTTP (VCR) and stub with WebMock, so the
  # request Sure's adapter builds is what's checked. ruby_llm-test stubs at
  # the provider instead: fast, provider-independent, but it wraps every
  # provider in the process, and a call with no stub left raises. In one
  # Minitest process that would break every recorded test, so it runs in a
  # child process here.
  test "ruby_llm-test and ruby_llm-instructor, stubbed, in a separate process" do
    script = <<~RUBY
      require "ruby_llm"
      require "ruby_llm/test"
      require "ruby_llm/instructor"
      require "active_model"
      RubyLLM.configure { |c| c.openai_api_key = "unused" }
      RubyLLM::Models.singleton_class.prepend(RubyLLM::Test::ResolveWithTestProvider)

      RubyLLM::Test.stub_response("Outlook good")
      out = { stubbed: RubyLLM.chat(model: "gpt-4.1-mini").ask("Odds?").content }
      out[:unstubbed] = begin
        RubyLLM.chat(model: "gpt-4.1-mini").ask("Anything?")
        "answered"
      rescue => e
        e.class.name
      end

      class Bill
        include ActiveModel::Validations
        attr_accessor :name, :amount
        validates :amount, numericality: { greater_than: 0 }
      end
      RubyLLM::Test.reset
      RubyLLM::Test.stub_responses({ name: "Netflix", amount: -15.49 }, { name: "Netflix", amount: 15.49 })
      out[:instructor] = begin
        bill = RubyLLM::Instructor::Client.new.chat(model: "gpt-4.1-mini", response_model: Bill, prompt: "NETFLIX.COM 15.49 monthly", max_retries: 1)
        [ bill.class.name, bill.amount ]
      rescue => e
        e.class.name + ": " + (e.message[/got \w+/] || e.message.lines.first.strip)
      end
      puts out.to_json
    RUBY
    output = IO.popen([ "bundle", "exec", "ruby", "-e", script ], chdir: Rails.root.to_s, err: File::NULL, &:read)
    result = JSON.parse(output.lines.last)

    assert_equal "Outlook good", result["stubbed"]
    assert_equal "RubyLLM::Test::Errors::NoResponseProvidedError", result["unstubbed"], "every provider in the process is wrapped"
    # instructor 0.2.0 (ruby_llm >= 1.15) expects 1.x's parsed content: 2.x keeps
    # content a JSON string and parses into response.parsed, so every reply fails.
    assert_match "Instructor::ValidationError", result["instructor"]
    assert_match "got String", result["instructor"]
  end

  # -- ruby_llm-registry: versioned prompt files -----------------------------
  #
  # Plan (§8.3): app/prompts/<name>.md with %{} placeholders, a locale file
  # per language, a family override, and the route naming a prompt. For the
  # registry: versions, labels, required variables, diffs. Against: its
  # bodies are ERB (a family override would run code), it has no locale or
  # per-family layer, and its labels move outside a deploy.
  test "ruby_llm-registry: a labelled version, ERB rendering with required variables, and a diff" do
    require "ruby_llm/registry"
    Dir.mktmpdir do |root|
      dir = FileUtils.mkdir_p(File.join(root, "categorize")).first
      File.write(File.join(dir, "v1.0.0.md"), "---\nversion: 1.0.0\nlabels: [production]\nrequired_vars: [categories]\n---\nCategorize into <%= categories %>.\n")
      File.write(File.join(dir, "v1.1.0.md"), "---\nversion: 1.1.0\nlabels: [staging]\nrequired_vars: [categories]\n---\nCategorize each transaction into one of <%= categories %>.\n")
      # Labels resolve through manifest.yml (or a file named after the label),
      # not the labels: front matter the README shows.
      assert_raises(RubyLLM::Registry::PromptNotFoundError) { RubyLLM::Registry.get("categorize", label: :production, root:) }
      File.write(File.join(root, "manifest.yml"), { "prompts" => { "categorize" => { "aliases" => { "production" => "1.0.0" } } } }.to_yaml)

      production = RubyLLM::Registry.get("categorize", label: :production, root:)
      assert_equal "1.0.0", production.version.to_s
      assert_equal "Categorize into Groceries, Rent.", production.render(categories: "Groceries, Rent").strip
      assert_raises(StandardError) { production.render }
      assert_equal "1.1.0", RubyLLM::Registry.get("categorize", root:).version.to_s, "latest without a label"
      assert_includes production.render(categories: "<%= `id` %>"), "<%= `id` %>", "a variable's value isn't evaluated; the template body is"
    end
  end

  # -- ruby_llm-turbovec: a vector index inside the Ruby process -------------
  #
  # Plan (§5.5): embeddings in pgvector or Qdrant, per family, behind
  # VectorStore. For turbovec: no database or service, quantized, saved to a
  # file. Against: the index lives in one process's memory or a file, so
  # Puma and Sidekiq processes each load their own, and nothing scopes it
  # to a family or keeps it in step with the database.
  test "ruby_llm-turbovec: add, search, save and load an index in process" do
    require "ruby_llm/turbovec"
    vectors = { 1 => [ 1, 0, 0, 0, 0, 0, 0, 0 ], 2 => [ 0, 1, 0, 0, 0, 0, 0, 0 ], 3 => [ 0.9, 0.1, 0, 0, 0, 0, 0, 0 ] }
    index = RubyLLM::Turbovec::IdMapIndex.new(8, 4)
    vectors.each { |id, vector| index.add_with_ids(vector.map(&:to_f), [ id ]) }

    _scores, ids = index.search([ 1.0, 0, 0, 0, 0, 0, 0, 0 ], 2)
    assert_equal [ 1, 3 ], ids.flatten.first(2)

    Dir.mktmpdir do |dir|
      path = File.join(dir, "family.tvim")
      index.write(path)
      _scores, reloaded = RubyLLM::Turbovec::IdMapIndex.load(path).search([ 0, 1.0, 0, 0, 0, 0, 0, 0 ], 1)
      assert_equal [ 2 ], reloaded.flatten
    end
  end

  # -- ruby_llm-monitoring: what its engine does to Sure's class names ---------
  #
  # Mounted normally, the engine's initializer deletes RubyLLM's "RubyLLM"
  # acronym and registers "LLM" app-wide (engine.rb:12-21). Zeitwerk then
  # expects LLMUsage in llm_usage.rb, so Sure's LlmUsage, LlmConcept and
  # LlmUsagesController stop loading. Here the change is applied to a copy
  # of the inflections and undone.
  test "ruby_llm-monitoring: its inflection would rename Sure's Llm classes" do
    store = ActiveSupport::Inflector::Inflections.instance_variable_get(:@__instance__)
    saved = store[:en]
    store[:en] = saved.dup
    ActiveSupport::Inflector.inflections(:en) do |inflections|
      inflections.acronyms.delete("rubyllm")
      inflections.acronym("LLM")
    end

    assert_equal %w[LLMUsage Provider::LLMConcept Settings::LLMUsagesController],
                 %w[llm_usage provider/llm_concept settings/llm_usages_controller].map(&:camelize)
    assert_equal [ LlmUsage, Provider::LlmConcept ], [ LlmUsage, Provider::LlmConcept ], "the classes Sure defines"
  ensure
    store[:en] = saved
  end

  # -- ruby_llm-monitoring: a dashboard over RubyLLM's events ------------------
  #
  # Plan (§10, §13): Sure's .ai events feed LlmUsage, Langfuse, DebugLogEntry
  # and the health page. Monitoring subscribes to every ruby_llm event and
  # stores its payload, minus a list of keys, in its own table. The question
  # for the tracing modes: does any prompt or answer text land in it?
  test "ruby_llm-monitoring: what a recorded chat leaves in its events table" do
    require "ruby_llm/monitoring"
    # The engine isn't mounted, so its app/models aren't on the load path.
    engine = Pathname(Gem.loaded_specs["ruby_llm-monitoring"].full_gem_path).join("app/models")
    %w[ruby_llm/monitoring/application_record concerns/ruby_llm/monitoring/alertable ruby_llm/monitoring/event].each { require engine.join(_1).to_s }
    ActiveRecord::Migration.suppress_messages do
      ActiveRecord::Schema.define do
        # Its migration says ruby_llm_monitoring_events; its model, unmounted
        # under RubyLLM's "RubyLLM" acronym, says rubyllm_monitoring_events.
        create_table RubyLLM::Monitoring::Event.table_name do |t|
          %i[allocations].each { t.integer _1 }
          %i[cost cpu_time duration end gc_time idle_time time].each { t.float _1 }
          t.string :name
          t.string :transaction_id
          t.json :payload
          t.timestamps
        end
      end
    end
    RubyLLM::Monitoring::Event.reset_column_information
    @errors = []
    recorder = RubyLLM::Monitoring::EventSubscriber.new
    # A savepoint per event, so one failed insert doesn't abort the test's transaction.
    subscriber = ActiveSupport::Notifications.subscribe(/ruby_llm/) do |event|
      ActiveRecord::Base.transaction(requires_new: true) { recorder.call(event) }
    rescue => e
      @errors << "#{event.name}: #{e.class.name}: #{e.message.lines.first.strip}"
    end

    endpoint = Ai::Spike::Presets.gemini(api_key: ENV.fetch("SPIKE_GEMINI_API_KEY", "gemini-key"), max_retries: 0)
    with_spike_cassette("features/streaming") do
      Ai::Transport.for(endpoint).send(:chat_for, Ai::Spike::Model.new(endpoint:, name: "gemini-3.5-flash-lite"))
                  .ask("Count from 1 to 20, comma separated.") { nil }
    end
    ActiveSupport::Notifications.unsubscribe(subscriber)

    events = RubyLLM::Monitoring::Event.all
    stored = events.map { _1.payload.to_json }.join
    puts "\n  monitoring: #{events.map(&:name).tally.inspect} keys #{events.flat_map { _1.payload.keys }.uniq.sort.inspect} errors #{@errors.uniq.inspect}" if ENV["SPIKE_PRINT"]
    assert events.any?
    assert_no_match(/Count from 1 to 20/, stored, "no prompt")
    assert_no_match(/1, 2, 3/, stored, "no answer")
  end
end
