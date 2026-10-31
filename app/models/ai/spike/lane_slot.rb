# Stands in for the plan's per-host slot (section 11) during the async spike:
# one Monitor per host, waiters ordered by lane, then arrival. size > 1 lets a
# server with parallel slots take that many calls; reserved keeps that many
# of them for the interactive lane, so a chat never waits for a running call.
# pause: while an interactive call runs or waits, no other call starts, so the
# running ones drain and the chat gets the server to itself.
# preempt: an interactive call that finds no room interrupts the running call
# of the lowest lane. A holder that registered an interrupt flag
# (with_interrupt) has the flag set, and its streamed call raises Preempted at
# the next chunk; this works on threads and fibers. Without one, under a
# fiber scheduler, Preempted is raised in its fiber (Fiber.scheduler.raise).
# Either way its HTTP request is abandoned, so the server should stop work on
# it; the caller decides whether to send it again.
class Ai::Spike::LaneSlot
  LANES = { interactive: 0, prompt: 1, background: 2 }.freeze

  class Preempted < StandardError; end

  # Marks the calls made in the block as interruptible by a flag: the
  # transport streams them and checks the flag at each chunk.
  def self.with_interrupt
    previous = ActiveSupport::IsolatedExecutionState[:ai_interrupt]
    ActiveSupport::IsolatedExecutionState[:ai_interrupt] = Concurrent::AtomicBoolean.new
    yield
  ensure
    ActiveSupport::IsolatedExecutionState[:ai_interrupt] = previous
  end

  def self.interrupt = ActiveSupport::IsolatedExecutionState[:ai_interrupt]

  def initialize(size = 1, reserved: 0, pause: false, preempt: false)
    @monitor = Monitor.new
    @size = size
    @reserved = reserved
    @pause = pause
    @preempt = preempt
    @busy = 0
    @interactive = 0
    @holders = {}.compare_by_identity   # waiter => lane
    @waiters = []
    @arrivals = 0
    @stats = { granted: 0, peak: 0, preempted: 0, longest_wait_s: Hash.new(0.0) }
  end

  # What the slot did: calls granted, most held at once, calls preempted, and
  # each lane's longest wait.
  def stats = @monitor.synchronize { @stats.merge(longest_wait_s: @stats[:longest_wait_s].transform_values { _1.round(2) }) }

  def hold(lane)
    acquire(lane)
    held = true
    yield
  ensure
    release(lane) if held
  end

  private
    def acquire(lane)
      queued = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      waiter = { lane: LANES.fetch(lane.to_sym), arrival: nil, cond: @monitor.new_cond, granted: false,
                 fiber: Fiber.current, interrupt: self.class.interrupt&.tap(&:make_false) }
      victim = @monitor.synchronize do
        waiter[:arrival] = @arrivals += 1
        @waiters << waiter
        @waiters.sort_by! { [ _1[:lane], _1[:arrival] ] }
        grant
        victim_for(waiter)
      end
      # Outside the monitor: the victim unwinds and releases its place.
      interrupt(victim) if victim
      @monitor.synchronize do
        waiter[:cond].wait_until { waiter[:granted] }
        waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - queued
        @stats[:longest_wait_s][lane.to_sym] = [ @stats[:longest_wait_s][lane.to_sym], waited ].max
      end
    end

    def victim_for(waiter)
      return unless @preempt && waiter[:lane].zero? && !waiter[:granted]

      victim, = @holders.select { |holder, lane| lane.positive? && (holder[:interrupt] || Fiber.scheduler) }.max_by { |_, lane| lane }
      @stats[:preempted] += 1 if victim
      victim
    end

    def interrupt(victim)
      if victim[:interrupt]
        victim[:interrupt].make_true
      else
        Fiber.scheduler.raise(victim[:fiber], Preempted, "preempted by an interactive call")
      end
    end

    def release(lane)
      @monitor.synchronize do
        @busy -= 1
        @interactive -= 1 if LANES.fetch(lane.to_sym).zero?
        @holders.delete_if { |holder, _| holder[:fiber] == Fiber.current }
        grant
      end
    end

    # Grants waiters in order while there's room; a waiter that can't run
    # yet (a background call when only reserved room is left) stops the
    # queue, so lane order holds.
    def grant
      while (waiter = @waiters.first) && room_for?(waiter)
        @waiters.shift
        @busy += 1
        @interactive += 1 if waiter[:lane].zero?
        @holders[waiter] = waiter[:lane]
        @stats[:granted] += 1
        @stats[:peak] = [ @stats[:peak], @busy ].max
        waiter[:granted] = true
        waiter[:cond].signal
      end
    end

    def room_for?(waiter)
      return @busy < @size if waiter[:lane].zero?
      return false if @pause && @interactive.positive?

      @busy < @size - @reserved
    end
end
