require_relative "spike_helper"

# Metadata tracing replays the recorded llama.cpp runs through RubyLLM's
# OpenTelemetry spans and checks that no prompt, tool result or answer ends up
# in any span.
class Ai::MetadataTracingTest < ActiveSupport::TestCase
  include AiSpikeHelper

  setup do
    @exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    Ai::Instrumentation::MetadataTracing.enable(processor: OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(@exporter))
  end

  teardown do
    RubyLLM::OpenTelemetry.disable
    OpenTelemetry.tracer_provider = OpenTelemetry::Trace::TracerProvider.new
  end

  def spans_text
    @exporter.finished_spans.map { |span| [ span.name, span.attributes, span.events, span.status.description ].to_json }.join("\n")
  end

  test "generate and two chat rounds give one span each, with model, usage and session but no content" do
    result = nil
    Ai::Correlation.with("sync-42") do
      with_spike_cassette("llama_cpp/generate_ruby_llm") { bill_setup.call(route: llama_route) }
      with_spike_cassette("llama_cpp/converse_tool_round") do
        result = Ai::Conversation.new(route: llama_route, functions: [ Assistant::Function::GetAccounts.new(users(:family_admin)) ],
                                      max_tool_rounds: 4, turn_timeout: 600,
                                      instructions: "You are a finance assistant. Use tools to look up the user's data. Be brief.")
                                 .respond([ Ai::Transport::Base::Message.new(role: :user, content: "How many accounts do I have? Look them up.") ])
      end
    end

    spans = @exporter.finished_spans
    assert_equal [ "chat #{LLAMA_MODEL}" ] * 3, spans.map(&:name)
    spans.each do |span|
      assert_equal "sync-42", span.attributes["session.id"]
      assert_equal LLAMA_MODEL, span.attributes["gen_ai.request.model"]
      assert_operator span.attributes["gen_ai.usage.output_tokens"], :>, 0
    end

    text = spans_text
    [ "NETFLIX", "CHARGE HISTORY", "Entertainment", "finance assistant", "How many accounts",
      result.messages[2].content, result.text ].each do |content|
      refute_includes text, content
    end
  end

  test "a failed call records RubyLLM's error class, not the error body" do
    stub_request(:post, %r{llama-cpp\.test/v1/chat/completions})
      .to_return(status: 500, headers: { "Content-Type" => "application/json" },
                 body: { error: { message: "server echoed NETFLIX.COM AUTOPAY" } }.to_json)
    endpoint = Ai::Spike::Presets.llama_cpp(base_url: "http://llama-cpp.test/v1", json_mode: "json_object")

    assert_raises(Ai::Error::Upstream) { bill_setup.call(route: llama_route(endpoint:)) }

    span = @exporter.finished_spans.sole
    assert_equal "RubyLLM::ServerError", span.attributes["error.type"]
    assert_equal OpenTelemetry::Trace::Status::ERROR, span.status.code
    refute_includes spans_text, "NETFLIX"
  end

  test "an unknown mode is refused" do
    assert_raises(ArgumentError) { Ai::Instrumentation.start_tracing("everything") }
  end
end
