require "test_helper"
require "async"

# The spike's stand-in for the plan's per-host slot, run on fibers.
class Ai::Spike::LaneSlotTest < ActiveSupport::TestCase
  def run_order(slot, arrivals)
    order = []
    Sync do |task|
      arrivals.map do |name, lane|
        task.async do
          slot.hold(lane) do
            order << name
            sleep 0.05
          end
        end.tap { sleep 0.01 }
      end.each(&:wait)
    end
    order
  end

  test "a waiting chat goes before background work that arrived earlier" do
    order = run_order(Ai::Spike::LaneSlot.new(1), [ [ "bg1", :background ], [ "bg2", :background ], [ "prompt", :prompt ], [ "chat", :interactive ] ])
    assert_equal %w[bg1 chat prompt bg2], order
  end

  test "a reserved place lets chat start while background work fills the rest" do
    slot = Ai::Spike::LaneSlot.new(2, reserved: 1)
    started = {}
    Sync do |task|
      %w[bg1 bg2].each { |name| task.async { slot.hold(:background) { started[name] = Process.clock_gettime(Process::CLOCK_MONOTONIC); sleep 0.2 } } }
      sleep 0.01
      task.async { slot.hold(:interactive) { started["chat"] = Process.clock_gettime(Process::CLOCK_MONOTONIC) } }
    end
    assert_operator started["chat"], :<, started["bg2"], "chat didn't wait for bg1"
    assert_operator started["bg2"] - started["bg1"], :>=, 0.2, "bg2 waited for bg1: only one background place"
  end

  test "the instrumenter holds the slot around requests only, and forwards every event" do
    lanes = []
    slot = Class.new { define_method(:hold) { |lane, &block| lanes << lane; block.call } }.new
    events = []
    delegate = Class.new { define_method(:instrument) { |name, payload, &block| events << name; block&.call(payload) } }.new
    instrumenter = Ai::Transport::SlotInstrumenter.new(slot, delegate)

    Ai::Transport::SlotInstrumenter.with_lane(:interactive) do
      assert_equal :response, instrumenter.instrument("request.ruby_llm", { url: "chat/completions" }) { :response }
    end
    instrumenter.instrument("complete_chat.ruby_llm", {}) { :chat }
    assert_equal %w[request.ruby_llm complete_chat.ruby_llm], events
    assert_equal [ :interactive ], lanes
  end
end
