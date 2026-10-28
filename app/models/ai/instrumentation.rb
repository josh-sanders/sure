# Tracing has two modes, and an operator picks one:
#   "content"  Sure's .ai events through LangfuseSubscriber: prompts, outputs,
#              usage, route and Sure's error class (the default);
#   "metadata" RubyLLM's own OpenTelemetry spans through MetadataTracing:
#              model, settings, tokens, latency and error class, no content.
# They never run together, or Langfuse would get each generation twice.
module Ai::Instrumentation
  MODES = %w[content metadata off].freeze

  module_function

  def start_tracing(mode, environment: Rails.env)
    case mode.to_s
    when "content" then ActiveSupport::Notifications.subscribe(/\.ai\z/, LangfuseSubscriber.new(environment:))
    when "metadata" then MetadataTracing.enable
    when "off" then nil
    else raise ArgumentError, "unknown tracing mode #{mode.inspect}; expected one of #{MODES.join(", ")}"
    end
  end
end
