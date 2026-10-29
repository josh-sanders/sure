require_relative "spike_helper"

# Spike: RubyLLM 2.1.1's own features, used the way its docs show rather than
# through Sure's adapter, each against the plan decision it bears on. Live on
# Gemini's free tier (OpenAI-compatible API, through Sure's RubyLLM context,
# so proxy, timeouts and keys are set as everywhere else), one request at a
# time. Each test notes the evidence for and against; none settles a product
# decision, which stays open.
class Ai::RubyLlmFeaturesLiveTest < ActiveSupport::TestCase
  include AiSpikeHelper

  MODEL = "gemini-3.5-flash-lite".freeze
  FILES = Rails.root.join("test/fixtures/files/statements")

  def endpoint(**overrides) = Ai::Spike::Presets.gemini(api_key: ENV.fetch("SPIKE_GEMINI_API_KEY", "gemini-key"), max_retries: 0, **overrides)
  def transport(**overrides) = Ai::Transport.for(endpoint(**overrides))
  def chat(**overrides) = transport(**overrides).send(:chat_for, Ai::Spike::Model.new(endpoint: endpoint(**overrides), name: MODEL))
  def bodies = request_bodies(%r{generativelanguage})

  def report(line) = (puts "\n  #{line}" if recording? || ENV["SPIKE_PRINT"])

  # Plan: Sure stores the history and rebuilds it each turn (§8.4).
  # For RubyLLM's history: two asks on one chat need no code; the second
  # request carries the first exchange. Against, for Sure: the history
  # lives in that Chat object only, so it ends with the job; a chat that
  # spans requests or workers needs storage, Sure's or RubyLLM's (see the
  # provider-switch spike).
  test "ask, then ask again: the chat keeps the history (live)" do
    with_spike_cassette("features/history") do
      @chat = chat.with_instructions("Be brief.")
      @chat.ask("My favourite number is 42. Just say OK.")
      @answer = @chat.ask("What is my favourite number?")
    end

    assert_match "42", @answer.content
    assert_equal %w[system user assistant user], bodies.last["messages"].map { _1["role"] }
    assert_equal 5, @chat.messages.size, "in memory: system, two questions, two answers"
  end

  # Plan: chat streams into the AssistantMessage (§8.4); BC4 streams
  # everywhere. RubyLLM streams with a block on any provider.
  test "streaming: a block receives the answer as it arrives (live)" do
    chunks = []
    with_spike_cassette("features/streaming") do
      @answer = chat.ask("Count from 1 to 20, comma separated.") { chunks << _1 }
    end

    assert_operator chunks.count { _1.content.present? }, :>, 1
    assert_equal @answer.content, chunks.map(&:content).join
    assert bodies.sole["stream"]
  end

  # Plan: extract_pdf sends page images or the text layer (PDF spike).
  # RubyLLM's with: takes paths, IO, URLs, several at once. An image URL goes
  # to the provider as a URL; anything else RubyLLM downloads itself from the
  # Rails process (Attachment#fetch_content), so a user-supplied URL would be
  # fetched by Sure's server: a product and security choice, not a limit.
  test "files: a local image, an image URL and two files at once (live)" do
    pages = Pdf::PageImages.pages(FILES.join("impact_scanned.pdf").binread)
    paths = pages.each_with_index.map { |png, i| Rails.root.join("tmp/spike_page_#{i + 1}.png").tap { File.binwrite(_1, png) }.to_s }
    url = "https://upload.wikimedia.org/wikipedia/commons/thumb/4/47/PNG_transparency_demonstration_1.png/280px-PNG_transparency_demonstration_1.png"

    with_spike_cassette("features/files") do
      @local = chat.ask("What is the ending balance on this statement page? Answer with the number only.", with: paths.first)
      @remote = begin
        chat.ask("What is in this picture? One short sentence.", with: url)
      rescue RubyLLM::BadRequestError => e
        e
      end
      @both = chat.ask("How many pages did I send, and what page numbers do they show? One sentence.", with: paths)
    end

    assert_match(/586\.71/, @local.content)
    image_parts = ->(body) { body["messages"].last["content"].select { _1["type"] == "image_url" }.map { _1.dig("image_url", "url")[0, 22] } }
    first, second, third = bodies
    assert_equal [ "data:image/png;base64," ], image_parts.(first), "a local file goes as a data URI"
    assert_equal [ url[0, 22] ], image_parts.(second), "an image URL goes to the provider as it is"
    assert_equal "Cannot fetch content from the provided URL.", @remote.message, "and Gemini's compatible API wouldn't fetch it"
    assert_equal [ "data:image/png;base64," ] * 2, image_parts.(third)
    assert_match(/\b2\b|two/i, @both.content)
  ensure
    Dir[Rails.root.join("tmp/spike_page_*.png")].each { FileUtils.rm_f(_1) }
  end

  test "files: a PDF URL is downloaded by the Rails process, not the provider (live)" do
    url = "https://www.impact-bank.com/user/file/dummy_statement.pdf"
    with_spike_cassette("features/files_pdf_url") do
      @error = begin
        chat.ask("Summarize this.", with: url)
        nil
      rescue RubyLLM::Error => e
        e
      end
    end

    downloads = WebMock::RequestRegistry.instance.requested_signatures.hash.keys.select { _1.uri.host == "www.impact-bank.com" }
    assert_equal [ :get ], downloads.map(&:method), "RubyLLM fetched the URL itself"
    assert_equal "file", bodies.sole["messages"].last["content"].find { _1["type"] != "text" }["type"]
    assert_kind_of RubyLLM::BadRequestError, @error, "Gemini's compatible API then refuses the file part, as in the PDF spike"
  end

  # 12 calls over 12 requests, then the spike's guard; RubyLLM would go on.
  EXPECTED_TOOL_LOOP = [ 12, 12, "spike guard: stopped after 12 calls" ].freeze
  # Compatible API: no price (assume_model_exists); native Gemini: priced.
  EXPECTED_COST = [ nil, false ].freeze

  class CountingTool < RubyLLM::Tool
    description "Returns the next page of the user's transactions. Keep calling it while it says more pages remain."
    parameter :page, type: :integer, description: "Page number, starting at 1"

    singleton_class.attr_accessor :calls

    def execute(page:)
      self.class.calls += 1
      raise "spike guard: stopped after 12 calls" if self.class.calls >= 12

      { page:, transactions: [ { name: "Coffee", amount: -3.5 } ], more_pages_remain: true, next_page: page + 1 }
    end
  end

  # Plan: Ai::Conversation owns the loop, with a round cap and a deadline
  # (§5.5). For RubyLLM's loop: ask runs tools and answers with no code.
  # Against: nothing bounds it. A tool that always says "more remains" was
  # called until the spike's own guard raised; RubyLLM has no round cap
  # (with_tool_options(calls:) limits calls per response, not rounds).
  test "tools: ask runs the loop itself, with no cap on rounds (live)" do
    CountingTool.calls = 0
    with_spike_cassette("features/tool_loop") do
      @error = begin
        chat.with_tools(CountingTool).ask("List all my transactions. Fetch every page.")
        nil
      rescue => e
        e
      end
    end

    report "tool loop: #{CountingTool.calls} calls, #{bodies.size} requests, #{@error&.message.inspect}"
    assert_equal EXPECTED_TOOL_LOOP, [ CountingTool.calls, bodies.size, @error&.message ] if defined?(EXPECTED_TOOL_LOOP)
  end

  class BillSchema < Schematist::Schema
    string :name, description: "Merchant name"
    number :amount, description: "Charge amount"
    string :frequency, enum: %w[weekly monthly yearly]
    integer :day_of_month, minimum: 1, maximum: 31
  end

  # Plan: Sure's JSON-mode chain (strict -> json_object -> none) and its own
  # schema hashes (§7). RubyLLM: with_schema(Schematist class) and
  # response.parsed, strict json_schema only, no fallback chain.
  test "structured output: a Schematist schema and response.parsed (live)" do
    with_spike_cassette("features/structured") do
      @answer = chat.with_schema(BillSchema).ask("NETFLIX.COM AUTOPAY charged 15.49 on the 15th of every month. Describe the bill.")
    end

    assert_equal({ "name" => "Netflix", "amount" => 15.49, "frequency" => "monthly", "day_of_month" => 15 },
                 @answer.parsed.slice("name", "amount", "frequency", "day_of_month").tap { _1["name"] = _1["name"].to_s[/netflix/i] ? "Netflix" : _1["name"] })
    format = bodies.sole["response_format"]
    assert_equal [ "json_schema", true ], [ format["type"], format.dig("json_schema", "strict") ]
  end

  # Plan: one declarative Ai::Generation per feature (§8.1). RubyLLM::Agent is
  # the same idea for chats: model, instructions and tools in a class.
  class SpikeAgent < RubyLLM::Agent
    # protocol: as everywhere in Sure's adapter: :openai defaults to the
    # Responses API, which Gemini's compatible API lacks (a bare 404).
    model MODEL, provider: :openai, protocol: :chat_completions, assume_model_exists: true
    instructions "You are a terse finance assistant. Answer in one sentence."
  end

  test "agents: a class with model and instructions, used with Sure's context (live)" do
    context = transport.send(:ruby_llm_context)
    with_spike_cassette("features/agent") do
      @answer = SpikeAgent.chat(context:).ask("What is a sinking fund?")
    end

    assert @answer.content.present?
    assert_equal "You are a terse finance assistant. Answer in one sentence.", bodies.sole["messages"].first["content"]
  end

  # Plan: failover between routes, only before the first chunk (§5.5), with
  # down marks. RubyLLM's fallbacks switch model inside one chat, on rate
  # limits, 5xx, overload, timeouts and refused connections, even after
  # chunks have streamed (before_fallback reports chunks_yielded). They can
  # move between providers in one context, not between two endpoints of the
  # same provider: :openai has one openai_api_base.
  test "fallbacks: a refused :openai endpoint falls back to native Gemini (live)" do
    context = RubyLLM.context do |config|
      config.openai_api_key = "none"
      config.openai_api_base = "http://127.0.0.1:9/v1"   # nothing listens on port 9
      config.gemini_api_key = ENV.fetch("SPIKE_GEMINI_API_KEY", "gemini-key")
      config.max_retries = 0
    end
    fallbacks = []
    # A refused connection can't be replayed, so it's always real: nothing listens on port 9.
    VCR.configuration.ignore_request { URI(_1.uri).port == 9 } unless self.class.instance_variable_get(:@port_nine)
    self.class.instance_variable_set(:@port_nine, true)
    with_spike_cassette("features/fallback") do
      @chat = context.chat(model: "local-model", provider: :openai, assume_model_exists: true)
                     .with_fallbacks(RubyLLM::Model.new(id: MODEL, provider: "gemini", name: MODEL))
      @chat.before_fallback { fallbacks << [ _1.error.class.name, _1.to.id ] }
      @answer = @chat.ask("Say OK.")
    end

    assert_equal [ [ "Faraday::ConnectionFailed", MODEL ] ], fallbacks
    assert @answer.content.present?
  end

  # Plan: Sure records usage in LlmUsage with its own prices (§10, §13).
  # RubyLLM knows tokens for every call and prices models in its registry,
  # but not models it doesn't know (every local model, and Gemini through
  # the compatible API with assume_model_exists).
  test "cost: tokens always, a price only for models in RubyLLM's registry (live)" do
    with_spike_cassette("features/cost") do
      @compatible = chat.ask("Say OK.")
      native = Ai::Transport.for(Ai::Spike::Presets.gemini_native(api_key: ENV.fetch("SPIKE_GEMINI_API_KEY", "gemini-key"), max_retries: 0))
      @native = native.send(:chat_for, Ai::Spike::Model.new(endpoint: native.endpoint, name: MODEL)).ask("Say OK.")
    end

    report "cost: compatible #{@compatible.tokens.to_h.inspect} #{@compatible.cost.to_h.inspect}; native #{@native.tokens.to_h.inspect} #{@native.cost.to_h.inspect}"
    assert_operator @compatible.tokens.input, :>, 0
    assert_operator @native.tokens.input, :>, 0
    assert_equal EXPECTED_COST, [ @compatible.cost.total, @native.cost.total.nil? ] if defined?(EXPECTED_COST)
  end
end
