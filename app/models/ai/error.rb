# The plan's error taxonomy (section 9). Transports map SDK and Faraday errors
# onto these; nothing above a transport rescues a provider's own classes.
module Ai::Error
  class Base < StandardError
    attr_reader :status

    def initialize(message = nil, status: nil)
      @status = status
      super(message)
    end
  end

  class Unavailable < Base
    attr_reader :reason

    def initialize(reason) = super("AI unavailable: #{@reason = reason}")
  end

  Cancelled      = Class.new(Base)
  Busy           = Class.new(Base)
  Unreachable    = Class.new(Base)   # connection refused / DNS
  Timeout        = Class.new(Base)
  RateLimited    = Class.new(Base)   # 429
  Upstream       = Class.new(Base)   # 5xx
  Unauthorized   = Class.new(Base)   # 401/403
  ContextTooLong = Class.new(Base)   # 400 saying the input is too long
  InvalidOutput  = Class.new(Base)   # parse / schema failure after the fallbacks
  Refused        = Class.new(Base)   # any other 4xx

  # Each provider words a context-length 400 differently. RubyLLM has its own
  # list; the hand-written transports use this one.
  CONTEXT_TOO_LONG = [
    /context length/i, /context window/i, /context size/i, /maximum context/i,
    /too many tokens/i, /prompt is too long/i, /reduce the length/i, /exceeds the available context/i
  ].freeze

  def self.from_status(status, message) = for_status(status, message).new(message, status:)

  def self.for_status(status, message)
    case status
    when 401, 403 then Unauthorized
    when 408 then Timeout
    when 429 then RateLimited
    when 500..599 then Upstream
    when 400, 413 then CONTEXT_TOO_LONG.any? { message.to_s.match?(_1) } ? ContextTooLong : Refused
    else Refused
    end
  end
end
