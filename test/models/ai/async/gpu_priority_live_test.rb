require_relative "async_spike_helper"

# Spike, step 2: one GPU at home, chat first. A flood of background bill
# setups is queued, then, 3 s later, one chat message; what matters is how
# long the person waits for the first word (time to first chunk, from the
# moment the chat job is enqueued) and how long the background work takes.
# All against llama.cpp on venus (SPIKE_LLAMA_CPP_URL), whose --parallel N
# decides how many requests it decodes at once (SPIKE_LLAMA_PARALLEL records
# what it was started with).
#
# Setups:
# - sidekiq_1: the plan's default, one AI thread, strict queue order (§11).
# - fifo_fibers: a Solid Queue fiber worker (fibers: 50), one queue, no
#   priority: every job's call goes to the server at once.
# - priority_fibers_1: Solid Queue, fibers: 1, the chat job at a higher
#   priority (Solid Queue's job priority, lower number first).
# - slot_fibers: fibers: 50, every call waits for the plan's per-host slot
#   (a Monitor, waiters ordered by lane), SPIKE_SLOT_SIZE calls at a time.
class Ai::AsyncGpuPriorityLiveTest < ActiveSupport::TestCase
  include AsyncSpikeHelper

  self.use_transactional_tests = false

  BACKGROUND = Integer(ENV.fetch("SPIKE_BACKGROUND_JOBS", "12"))
  CHAT_AFTER = 3
  LANES = { interactive: 0, background: 2 }.freeze

  # The plan's slot (§11): one Monitor per host, waiters ordered by lane,
  # then arrival. size > 1 lets a server with parallel slots take that many.
  class LaneSlot
    def initialize(size)
      @monitor = Monitor.new
      @size = size
      @busy = 0
      @waiters = []
      @arrivals = 0
    end

    def hold(lane)
      acquire(lane)
      yield
    ensure
      release
    end

    private
      def acquire(lane)
        @monitor.synchronize do
          waiter = { lane: LANES.fetch(lane), arrival: @arrivals += 1, cond: @monitor.new_cond, granted: false }
          if @busy < @size && @waiters.empty?
            @busy += 1
            return
          end
          @waiters << waiter
          @waiters.sort_by! { [ _1[:lane], _1[:arrival] ] }
          waiter[:cond].wait_until { waiter[:granted] }
        end
      end

      def release
        @monitor.synchronize do
          if (waiter = @waiters.shift)
            waiter[:granted] = true
            waiter[:cond].signal
          else
            @busy -= 1
          end
        end
      end
  end

  singleton_class.attr_accessor :slot

  class GpuJob < ApplicationJob
    def perform(kind, lane)
      slot = Ai::AsyncGpuPriorityLiveTest.slot
      record = { kind:, started: AsyncSpikeHelper.clock }
      call = -> { kind == "chat" ? Ai::AsyncGpuPriorityLiveTest.chat(record) : Ai::AsyncGpuPriorityLiveTest.background(record) }
      slot ? slot.hold(lane.to_sym, &call) : call.call
      record[:finished] = AsyncSpikeHelper.clock
      RESULTS << record
    end
  end

  class SidekiqGpuJob < GpuJob
    self.queue_adapter = :sidekiq
  end

  class SolidQueueGpuJob < GpuJob
    self.queue_adapter = :solid_queue if defined?(SolidQueue)   # loaded with SPIKE_ASYNC=1
  end

  def self.route
    endpoint = Ai::Spike::Presets.llama_cpp(timeout_seconds: 600, json_mode: "strict")
    Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint:, name: AiSpikeHelper::LLAMA_MODEL, max_output_tokens: 1024), reasoning_effort: "none")
  end

  def self.background(record)
    record[:called] = AsyncSpikeHelper.clock
    AsyncSpikeHelper.bill_setup.call(route:)
  rescue => e
    record[:error] = "#{e.class}: #{e.message.truncate(120)}"
  end

  def self.chat(record)
    request = Ai::Transport::Base::ConverseRequest.new(
      model: route.model, instructions: "Answer in one short sentence.", reasoning_effort: "none", max_tokens: 200,
      messages: [ Ai::Transport::Base::Message.new(role: :user, content: "What does a monthly Netflix bill of 15.49 cost over a year?") ]
    )
    record[:called] = AsyncSpikeHelper.clock
    turn = Ai::Transport.for(route.endpoint).converse(request) { record[:first_chunk] ||= AsyncSpikeHelper.clock }
    record[:text] = turn.text.to_s.truncate(80)
  rescue => e
    record[:error] = "#{e.class}: #{e.message.truncate(120)}"
  end

  setup do
    skip "live only: SPIKE_ASYNC=1 and SPIKE_LLAMA_CPP_URL" unless ENV["SPIKE_ASYNC"] == "1" && ENV["SPIKE_LLAMA_CPP_URL"].present?
    WebMock.disable!
    RESULTS.clear
    self.class.slot = nil
  end

  teardown do
    WebMock.enable!
  end

  test "sidekiq_1: one AI thread, strict queue order" do
    require "sidekiq/api"
    queues = %w[spike_gpu_interactive spike_gpu_background]
    queues.each { Sidekiq::Queue.new(_1).clear }
    instance = Sidekiq.configure_embed do |config|
      config.queues = queues   # no weights: strict order
      config.concurrency = 1
      config.logger.level = Logger::WARN
    end
    instance.run
    measure("sidekiq_1") do |kind|
      SidekiqGpuJob.set(queue: kind == "chat" ? "spike_gpu_interactive" : "spike_gpu_background")
    end
  ensure
    instance&.stop
  end

  test "fifo_fibers: Solid Queue, fibers: 50, one queue" do
    with_solid_queue(fibers: 50) { measure("fifo_fibers") { SolidQueueGpuJob.set(queue: QUEUE) } }
  end

  test "priority_fibers_1: Solid Queue, fibers: 1, chat at a higher priority" do
    with_solid_queue(fibers: 1) do
      measure("priority_fibers_1") { |kind| SolidQueueGpuJob.set(queue: QUEUE, priority: kind == "chat" ? 0 : 10) }
    end
  end

  test "slot_fibers: Solid Queue, fibers: 50, the plan's lane-ordered slot" do
    size = Integer(ENV.fetch("SPIKE_SLOT_SIZE", "1"))
    self.class.slot = LaneSlot.new(size)
    with_solid_queue(fibers: 50) { measure("slot_fibers_#{size}") { SolidQueueGpuJob.set(queue: QUEUE) } }
  end

  private
    def measure(name)
      started = clock
      BACKGROUND.times { yield("background").perform_later("background", "background") }
      sleep CHAT_AFTER
      chat_enqueued = clock
      yield("chat").perform_later("chat", "interactive")
      results = (BACKGROUND + 1).times.filter_map { RESULTS.pop(timeout: 1800) }
      finished = clock

      chat = results.find { _1[:kind] == "chat" }
      background = results.select { _1[:kind] == "background" }
      summary = {
        setup: name, llama_parallel: ENV["SPIKE_LLAMA_PARALLEL"], background_jobs: background.size,
        chat_first_chunk_s: chat[:first_chunk] && (chat[:first_chunk] - chat_enqueued).round(1),
        chat_done_s: (chat[:finished] - chat_enqueued).round(1),
        background_done_s: (background.map { _1[:finished] }.max - started).round(1),
        background_call_s: background.map { (_1[:finished] - _1[:called]).round(1) }.minmax,
        background_after_chat: background.count { _1[:called] > chat_enqueued },
        errors: results.filter_map { _1[:error] }.tally, chat_text: chat[:text]
      }
      puts "\n  #{summary.inspect}"
      assert_equal BACKGROUND + 1, results.size
    end
end
