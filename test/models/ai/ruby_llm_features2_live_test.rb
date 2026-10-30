require_relative "spike_helper"

# Spike: RubyLLM 2.1.1 features, second batch: approval inside ask, web
# search with citations, provider batches, prompt caching, text to speech,
# moderation, OCR and video. Gemini's free tier through RubyLLM's native
# provider, in Sure's RubyLLM context; OpenAI and Mistral where they're the
# only providers. Each runs to its result or its error, and the error is
# the evidence: a free tier that refuses a feature is a cost fact for the
# product decision, not a verdict on it.
class Ai::RubyLlmFeatures2LiveTest < ActiveSupport::TestCase
  include AiSpikeHelper

  MODEL = "gemini-3.5-flash-lite".freeze

  # Gemini's free tier, 2026-10-30: speech works; web search is refused for
  # quota every time; batches need billing; explicit caching is capped at 0
  # tokens. Moderation works on an OpenAI key without credits. Video: the
  # registry's Veo model is retired, and Google's replacement isn't served
  # for predictLongRunning, the call RubyLLM 2.1.1 makes.
  EXPECTED = {
    web_search: "RateLimitError: You exceeded your current quota, please check your plan and billing details. For more information on this error, head to: https://ai.google.dev/gemini-api/do...",
    batch: "BadRequestError: Precondition check failed.",
    caching: "RateLimitError: TotalCachedContentStorageTokensPerModelFreeTier limit exceeded for model gemini-3.5-flash-lite: limit=0, requested=10783",
    speech: { format: "pcm", bytes: true },
    moderation: { flagged: false },
    video: "Error: models/gemini-omni-1.1-flash is not found for API version v1beta, or is not supported for predictLongRunning. Call ModelService.ListModels to see the list of..."
  }.freeze

  def gemini = Ai::Transport.for(Ai::Spike::Presets.gemini_native(api_key: ENV.fetch("SPIKE_GEMINI_API_KEY", "gemini-key"), max_retries: 0))
  def context = gemini.send(:ruby_llm_context)
  def chat = context.chat(model: MODEL, provider: :gemini, assume_model_exists: true)
  def calls(host = %r{generativelanguage}) = WebMock::RequestRegistry.instance.requested_signatures.hash.keys.select { _1.uri.to_s.match?(host) }

  def report(line) = (puts "\n  #{line}" if recording? || ENV["SPIKE_PRINT"])

  def outcome
    yield
  rescue RubyLLM::Error, RubyLLM::ConfigurationError, ArgumentError, NotImplementedError => e
    e
  end

  def summary(error) = "#{error.class.name.demodulize}: #{error.message.to_s.truncate(160)}"

  class DeleteTagTool < RubyLLM::Tool
    description "Deletes one of the user's tags by name."
    parameter :name, description: "The tag's name"
    requires_approval

    singleton_class.attr_accessor :deleted

    # A nested class is otherwise named after its whole namespace.
    def name = "delete_tag"

    def execute(name:)
      self.class.deleted = name
      { deleted: name }
    end
  end

  # Plan: write tools run as soon as the model calls them (§8.4). Against:
  # requires_approval stops ask itself, not just run_tools, until a person
  # decides. For: the decision has to live somewhere a later request can
  # find it (see the loop spike).
  test "approval: ask stops before a tool that requires it, and complete runs it once approved (live)" do
    DeleteTagTool.deleted = nil
    with_spike_cassette("features/approval") do
      @chat = chat.with_tools(DeleteTagTool)
      @paused = @chat.ask("Delete my tag called Ski trip.")
      @waiting = [ @chat.awaiting_approval?, @chat.pending_approvals.map(&:name), DeleteTagTool.deleted ]
      @chat.approve(@chat.pending_approvals.first)
      @answer = @chat.complete
    end

    assert_equal [ true, [ "delete_tag" ], nil ], @waiting, "paused, nothing deleted"
    assert_equal "Ski trip", DeleteTagTool.deleted
    assert @answer.content.present?
  end

  # Plan: chat's tools reach only the family's data (§8.4); web access isn't
  # planned. For web search: answers with sources, one line of code. Against:
  # the question, which can quote the family's finances, goes to a search
  # engine, and search is billed per use outside cost.total.
  test "provider tools: Gemini's web search answers with citations (live)" do
    with_spike_cassette("features/web_search") do
      @answer = outcome { chat.with_provider_tools(:web_search).ask("What is the current Bank of England base rate? Cite your source.") }
    end

    @summary = @answer.is_a?(Exception) ? summary(@answer) : { citations: @answer.citations.size, server_tool_use: @answer.tokens.server_tool_use, suggestions: @answer.server_tool_calls.filter_map(&:search_suggestions).any? }
    report "web search: #{@summary.inspect}"
    assert_equal EXPECTED.fetch(:web_search), @summary if defined?(EXPECTED)
  end

  # Plan: categorizing fans out interactive requests (§8.1). For provider
  # batches: lower prices, one submission. Against: results come back when
  # the provider is ready (minutes to a day), headers set with with_headers
  # aren't sent, and Sure's lanes and per-family locks assume a reply now.
  test "batches: two chats submitted as one Gemini batch, then cancelled (live)" do
    with_spike_cassette("features/batch") do
      @result = outcome do
        chats = %w[NETFLIX SHELL].map { chat.ask_later("One word: what kind of merchant is #{_1}?") }
        batch = RubyLLM.batch(chats)
        status = batch.refresh.status
        batch.cancel
        { id: batch.id.present?, status:, requests: chats.size }
      end
    end

    @summary = @result.is_a?(Exception) ? summary(@result) : @result
    report "batch: #{@summary.inspect}"
    assert_equal EXPECTED.fetch(:batch), @summary if defined?(EXPECTED)
  end

  # Plan: nothing on caching. Sure's 34 tools are 12,418 tokens every round.
  # For: Gemini's explicit cache holds instructions once. Against: Gemini
  # refuses a cache together with request-level instructions or tools, so
  # the tools would have to live in the cache, per model.
  test "prompt caching: a Gemini cache of Sure's tool descriptions, then a chat that reads it (live)" do
    user = users(:family_admin)
    reference = Assistant.function_classes(user).map { _1.new(user) }.map { "## #{_1.name}\n#{_1.description}\n#{_1.params_schema.to_json}" }.join("\n\n")
    with_spike_cassette("features/caching") do
      @result = outcome do
        cache = context.cache(reference, model: MODEL, provider: :gemini, instructions: "You answer questions about these tools.", ttl: 300)
        answer = chat.with_caching(id: cache).ask("Which tool creates a tag? Answer with its name.")
        cache.delete
        { cached: cache.tokens, read: answer.tokens.cache_read, answer: answer.content.to_s[/create_tag/] }
      end
    end

    @summary = @result.is_a?(Exception) ? summary(@result) : @result
    report "caching: #{@summary.inspect}"
    assert_equal EXPECTED.fetch(:caching), @summary if defined?(EXPECTED)
  end

  # Plan: no voice. For: the same context speaks. Against: a new data flow
  # (the answer, read aloud by a third party) for a feature nobody asked for.
  test "text to speech: Gemini reads a sentence aloud (live)" do
    with_spike_cassette("features/speech") do
      @result = outcome do
        speech = context.speak("Your Netflix bill of 15.49 is due on the 15th.", model: "gemini-3.1-flash-tts-preview", provider: :gemini, voice: "Kore")
        { format: speech.format, bytes: speech.to_blob.bytesize > 10_000 }
      end
    end

    @summary = @result.is_a?(Exception) ? summary(@result) : @result
    report "speech: #{@summary.inspect}"
    assert_equal EXPECTED.fetch(:speech), @summary if defined?(EXPECTED)
  end

  # Plan: no moderation of chat input. Moderation is OpenAI's (or Mistral's,
  # or Bedrock's guardrails); the OpenAI key has no credits.
  test "moderation: OpenAI's free endpoint on a key without credits (live)" do
    openai = Ai::Transport.for(Ai::Spike::Presets.openai(api_key: ENV.fetch("SPIKE_OPENAI_API_KEY", "sk-openai"), max_retries: 0))
    with_spike_cassette("features/moderation") do
      @result = outcome do
        result = openai.send(:ruby_llm_context).moderate("I love programming in Ruby.")
        { flagged: result.flagged? }
      end
    end

    @summary = @result.is_a?(Exception) ? summary(@result) : @result
    report "moderation: #{@summary.inspect}"
    assert_equal EXPECTED.fetch(:moderation), @summary if defined?(EXPECTED)
  end

  # Plan: local OCR as a transcribe step (OCR spike). RubyLLM.ocr is
  # Mistral's or Cohere's; no key here.
  test "OCR: RubyLLM.ocr without a Mistral key" do
    @result = outcome { context.ocr(Rails.root.join("test/fixtures/files/statements/impact_scanned.pdf").to_s, model: "mistral-ocr-latest", provider: :mistral) }
    assert_kind_of Exception, @result
    report "ocr: #{summary(@result)}"
  end

  # No plan counterpart. RubyLLM's registry offered veo-3.1-lite-generate-preview,
  # which Google has retired ("no longer available ... use
  # models/gemini-omni-1.1-flash"); this asks for the one Google named.
  test "video: Veo on Gemini's free tier (live)" do
    with_spike_cassette("features/video") do
      @result = outcome { context.animate("A paper boat on a rainy street.", model: "gemini-omni-1.1-flash", provider: :gemini, assume_model_exists: true) }
    end

    @summary = @result.is_a?(Exception) ? summary(@result) : @result.class.name
    report "video: #{@summary.inspect}"
    assert_equal EXPECTED.fetch(:video), @summary if defined?(EXPECTED)
  end
end
