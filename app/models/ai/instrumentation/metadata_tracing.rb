require "opentelemetry/sdk"
require "opentelemetry-exporter-otlp"

# Tracing for operators who don't want prompts or answers to leave the
# server. RubyLLM's OpenTelemetry spans carry no message content, and go to
# any OTLP collector set by the standard OTEL_EXPORTER_OTLP_* variables
# (Langfuse, Tempo, Jaeger, OpenObserve).
module Ai::Instrumentation::MetadataTracing
  # RubyLLM can't set a session, and Langfuse doesn't copy one from a parent
  # span, so every span gets the job's correlation id when it starts.
  class CorrelationProcessor < OpenTelemetry::SDK::Trace::SpanProcessor
    def on_start(span, _parent_context)
      id = Ai::Correlation.current
      span.set_attribute("session.id", id.to_s) if id
    end
  end

  module_function

  def enable(processor: OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(OpenTelemetry::Exporter::OTLP::Exporter.new))
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(CorrelationProcessor.new)
    provider.add_span_processor(processor)
    OpenTelemetry.tracer_provider = provider
    RubyLLM::OpenTelemetry.enable
    provider
  end
end
