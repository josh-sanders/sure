# Stands in for the plan's per-host slot (section 11) during the async spike:
# one Monitor per host, waiters ordered by lane, then arrival. size > 1 lets a
# server with parallel slots take that many calls; reserved keeps that many
# of them for the interactive lane, so a chat never waits for a running call.
class Ai::Spike::LaneSlot
  LANES = { interactive: 0, prompt: 1, background: 2 }.freeze

  def initialize(size = 1, reserved: 0)
    @monitor = Monitor.new
    @size = size
    @reserved = reserved
    @busy = 0
    @waiters = []
    @arrivals = 0
    @stats = { granted: 0, peak: 0, longest_wait_s: Hash.new(0.0) }
  end

  # What the slot did: calls granted, most held at once, and each lane's
  # longest wait.
  def stats = @monitor.synchronize { @stats.merge(longest_wait_s: @stats[:longest_wait_s].transform_values { _1.round(2) }) }

  def hold(lane)
    acquire(lane)
    held = true
    yield
  ensure
    release if held
  end

  private
    def acquire(lane)
      @monitor.synchronize do
        waiter = { lane: LANES.fetch(lane.to_sym), arrival: @arrivals += 1, cond: @monitor.new_cond, granted: false }
        queued = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @waiters << waiter
        @waiters.sort_by! { [ _1[:lane], _1[:arrival] ] }
        grant
        waiter[:cond].wait_until { waiter[:granted] }
        waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - queued
        @stats[:longest_wait_s][lane.to_sym] = [ @stats[:longest_wait_s][lane.to_sym], waited ].max
      end
    end

    def release
      @monitor.synchronize do
        @busy -= 1
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
        @stats[:granted] += 1
        @stats[:peak] = [ @stats[:peak], @busy ].max
        waiter[:granted] = true
        waiter[:cond].signal
      end
    end

    def room_for?(waiter)
      limit = waiter[:lane].zero? ? @size : @size - @reserved
      @busy < limit
    end
end
