require_relative "spike_helper"

# Spike: a chat that changes provider partway through, as when a family
# changes its chat model, routing differs by task, or a failover lands
# between rounds. Sure stores the history and rebuilds it each turn, so
# provider_state (thought signatures, reasoning_details, reasoning text)
# from one provider reaches the next. RubyLLM 2.1 drops another provider's
# native content only when a message carries RubyLLM's own usage record of
# who produced it; "a message with no known producer replays as it is"
# (lib/ruby_llm/protocol.rb:589-597), and Sure's rebuilt messages have none.
class Ai::ProviderSwitchLiveTest < ActiveSupport::TestCase
  include AiSpikeHelper

  T = Ai::Transport::Base
  INSTRUCTIONS = "You are a finance assistant. Use tools to look up the user's data. Be brief.".freeze

  setup { @user = users(:family_admin) }

  def routes
    {
      gemini: Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint: Ai::Spike::Presets.gemini(max_retries: 0), name: "gemini-3.5-flash-lite", max_output_tokens: 4096),
                                   reasoning_effort: "low"),
      gemini_native: Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint: Ai::Spike::Presets.gemini_native(api_key: ENV.fetch("SPIKE_GEMINI_API_KEY", "gemini-key"), max_retries: 0),
                                                                      name: "gemini-3.5-flash-lite", max_output_tokens: 4096), reasoning_effort: "low"),
      nemotron: Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint: Ai::Spike::Presets.openrouter(api_key: ENV.fetch("SPIKE_OPENROUTER_API_KEY", "or-key"), max_retries: 0),
                                                                 name: "nvidia/nemotron-3.5-lightning:free", max_output_tokens: 4096)),
      # The venus llama.cpp had gpt-oss-20b loaded: it always reasons, so its
      # reasoning text is the state that could travel.
      llama: Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint: Ai::Spike::Presets.llama_cpp(timeout_seconds: 900), name: "gpt-oss-20b", max_output_tokens: 4096))
    }
  end

  HOSTS = { gemini: %r{generativelanguage}, gemini_native: %r{generativelanguage}, nemotron: %r{openrouter\.ai}, llama: %r{llama-cpp\.test|8180} }.freeze

  def conversation(provider)
    Ai::Conversation.new(route: routes.fetch(provider), max_tool_rounds: 4, turn_timeout: 600, instructions: INSTRUCTIONS,
                         functions: [ Assistant::Function::GetAccounts.new(@user), Assistant::Function::GetCategories.new(@user) ])
  end

  def ask(text) = T::Message.new(role: :user, content: text)

  def attempt
    yield
  rescue Ai::Error::Base => e
    e
  end

  # What the first provider left on its messages that the second one was
  # sent: fields beyond role, content and tool_calls, and on tool calls
  # beyond id, type and function.
  def foreign_fields(provider)
    body = request_bodies(HOSTS.fetch(provider)).first
    # Gemini's own API: the parts of the model's turns.
    return body["contents"].select { _1["role"] == "model" }.flat_map { |c| c["parts"].flat_map(&:keys) }.uniq.sort if body.key?("contents")

    assistant = body["messages"].select { _1["role"] == "assistant" }
    (assistant.flat_map { _1.keys - %w[role content tool_calls] } +
      assistant.flat_map { Array(_1["tool_calls"]).flat_map { |call| call.keys - %w[id type function] } }).uniq.sort
  end

  def outcome(result)
    return "#{result.class.name.demodulize}: #{result.message.truncate(140)}" if result.is_a?(Exception)

    { rounds: result.rounds, tools: result.messages.flat_map { _1.tool_calls.map(&:name) }, answered: result.text.present? }
  end

  def report(line) = (puts "\n  #{line}" if recording? || ENV["SPIKE_PRINT"])

  # How Sure rebuilds the history: as today; with the producer RubyLLM's own
  # history would carry; with Google's placeholder signature on the
  # compatible API. The native variant is the gemini_native route.
  VARIANTS = { today: {}, producers: { restore_producers: true }, placeholder: { gemini_placeholder: true } }.freeze

  RUNS = [
    [ :today, :turns, :gemini, :llama ], [ :today, :turns, :llama, :gemini ], [ :today, :round, :gemini, :llama ], [ :today, :round, :llama, :gemini ],
    [ :producers, :turns, :gemini, :llama ], [ :producers, :turns, :llama, :gemini ], [ :producers, :round, :gemini, :llama ], [ :producers, :round, :llama, :gemini ],
    [ :placeholder, :round, :llama, :gemini ],
    [ :today, :turns, :llama, :gemini_native ], [ :today, :round, :llama, :gemini_native ], [ :today, :round, :gemini_native, :llama ]
  ].freeze

  def cassette(variant, kind, from, to) = "switch/#{"#{variant}_" unless variant == :today}#{kind}_#{from}_#{to}"

  def with_variant(variant)
    VARIANTS.fetch(variant).each { |knob, value| Ai::Transport::RubyLlmAdapter.public_send("#{knob}=", value) }
    yield
  ensure
    Ai::Transport::RubyLlmAdapter.restore_producers = Ai::Transport::RubyLlmAdapter.gemini_placeholder = nil
  end

  RUNS.each do |variant, kind, from, to|
    test "#{variant}, #{kind}: #{from}, then #{to} (live)" do
      name = cassette(variant, kind, from, to)
      skip "not recorded yet" unless recording? || Rails.root.join("test/vcr_cassettes/ai/#{name}.yml").exist?

      with_variant(variant) { kind == :turns ? across_turns(name, from, to) : mid_turn(name, from, to) }
      report "#{variant} #{kind} #{from} -> #{to}: #{@summary.inspect}"
      assert_equal EXPECTED.fetch([ variant, kind, from, to ]), @summary unless recording?
    end
  end

  def across_turns(name, from, to)
    with_spike_cassette(name) do
      @first = conversation(from).respond([ ask("How many accounts do I have? Look them up.") ])
      @second = attempt { conversation(to).respond(@first.messages + [ ask("And how many categories do I have? Look them up.") ]) }
    end
    @summary = { first: outcome(@first), second: outcome(@second), sent: foreign_fields(to) }
  end

  # A failover between rounds: one provider asks for the tool, Sure runs
  # it, the other answers.
  def mid_turn(name, from, to)
    history = [ ask("How many accounts do I have? Look them up.") ]
    with_spike_cassette(name) do
      first = conversation(from)
      turn = Ai::Transport.for(routes.fetch(from).endpoint).converse(first.send(:request, history, final: false, round: 1))
      @call = T::Message.new(role: :assistant, content: turn.text, tool_calls: turn.tool_calls, provider_state: turn.provider_state)
      @second = attempt { conversation(to).respond(history + [ @call ] + first.send(:run_tools, turn.tool_calls)) }
    end
    @summary = { asked: @call.tool_calls.map(&:name), second: outcome(@second), sent: foreign_fields(to) }
  end

  EXPECTED = {
    [ :placeholder, :round, :llama, :gemini ] => { asked: [ "get_accounts" ], second: { rounds: 1, tools: [ "get_accounts" ], answered: true }, sent: [ "extra_content", "reasoning", "reasoning_content" ] },
    [ :producers, :round, :gemini, :llama ] => { asked: [ "get_accounts" ], second: { rounds: 1, tools: [ "get_accounts" ], answered: true }, sent: [] },
    [ :producers, :round, :llama, :gemini ] => { asked: [ "get_accounts" ], second: "Refused: Function call is missing a thought_signature in functionCall parts. This is required for tools to work correctly, and missing thought_sig...", sent: [] },
    [ :producers, :turns, :gemini, :llama ] => { first: { rounds: 2, tools: [ "get_accounts" ], answered: true }, second: { rounds: 2, tools: [ "get_accounts", "get_categories" ], answered: true }, sent: [] },
    [ :producers, :turns, :llama, :gemini ] => { first: { rounds: 2, tools: [ "get_accounts" ], answered: true }, second: { rounds: 2, tools: [ "get_accounts", "get_categories" ], answered: true }, sent: [] },
    [ :today, :round, :gemini, :llama ] => { asked: [ "get_accounts" ], second: { rounds: 1, tools: [ "get_accounts" ], answered: true }, sent: [ "extra_content" ] },
    [ :today, :round, :gemini_native, :llama ] => { asked: [ "get_accounts" ], second: { rounds: 1, tools: [ "get_accounts" ], answered: true }, sent: [ "extra_content", "reasoning_signature" ] },
    [ :today, :round, :llama, :gemini ] => { asked: [ "get_accounts" ], second: "Refused: Function call is missing a thought_signature in functionCall parts. This is required for tools to work correctly, and missing thought_sig...", sent: [ "reasoning", "reasoning_content" ] },
    [ :today, :round, :llama, :gemini_native ] => { asked: [ "get_accounts" ], second: { rounds: 1, tools: [ "get_accounts" ], answered: true }, sent: [ "functionCall", "thoughtSignature" ] },
    [ :today, :turns, :gemini, :llama ] => { first: { rounds: 2, tools: [ "get_accounts" ], answered: true }, second: { rounds: 2, tools: [ "get_accounts", "get_categories" ], answered: true }, sent: [ "extra_content" ] },
    [ :today, :turns, :llama, :gemini ] => { first: { rounds: 2, tools: [ "get_accounts" ], answered: true }, second: { rounds: 2, tools: [ "get_accounts", "get_categories" ], answered: true }, sent: [ "reasoning", "reasoning_content" ] },
    [ :today, :turns, :llama, :gemini_native ] => { first: { rounds: 2, tools: [ "get_accounts" ], answered: true }, second: { rounds: 2, tools: [ "get_accounts", "get_categories" ], answered: true }, sent: [ "functionCall", "text" ] }
  }.freeze
end
