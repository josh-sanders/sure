# Spike (async): the plan's per-host slot inside RubyLLM. RubyLLM wraps every
# HTTP request it makes, streamed or not and with its retries, in
# instrument("request.ruby_llm") on the context's instrumenter, a public
# setting. This instrumenter holds the endpoint host's slot for the length of
# that block, in the current job's lane, and passes every event on to the
# instrumenter it replaced (ActiveSupport::Notifications under Rails).
class Ai::Transport::SlotInstrumenter
  # host => Ai::Spike::LaneSlot; nil (the default) leaves RubyLLM as it is.
  singleton_class.attr_accessor :slots

  def self.for(endpoint, delegate)
    slot = slots&.[](URI(endpoint.base_url).host)
    slot ? new(slot, delegate) : delegate
  end

  # The lane of the AI work running in this fiber or thread.
  def self.with_lane(lane)
    previous = ActiveSupport::IsolatedExecutionState[:ai_lane]
    ActiveSupport::IsolatedExecutionState[:ai_lane] = lane
    yield
  ensure
    ActiveSupport::IsolatedExecutionState[:ai_lane] = previous
  end

  def self.lane = ActiveSupport::IsolatedExecutionState[:ai_lane] || :background

  def initialize(slot, delegate)
    @slot = slot
    @delegate = delegate
  end

  def instrument(name, payload = {}, &block)
    return forward(name, payload, &block) unless name == "request.ruby_llm" && block

    @slot.hold(self.class.lane) { forward(name, payload, &block) }
  end

  private
    def forward(name, payload, &block)
      if @delegate.respond_to?(:instrument)
        block ? @delegate.instrument(name, payload, &block) : @delegate.instrument(name, payload)
      elsif block
        yield payload
      end
    end
end
