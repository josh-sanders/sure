require_relative "async_spike_helper"

# Spike, step 2c: merchant detection and chat on the same model. Both go to
# qwen3.6 on llama.cpp (SPIKE_LLAMA_CPP_URL). llama-server answers requests
# in arrival order: once its slots are full, a request waits in its own
# queue, where nothing Sure does can move it. So Sure has to drain into the
# server, sending no more calls than it has slots (total_slots from /props),
# and keep the rest in its own queue, chat first. The slot lives inside
# RubyLLM: every request passes through the context's instrumenter
# (Ai::Transport::SlotInstrumenter), which holds the host's slot in the job's
# lane.
#
# MERCHANT_JOBS detect_merchants jobs (the prompt lane, MERCHANT_BATCH
# transactions each) are queued, then, CHAT_AFTER seconds later, one chat
# message with a few thousand tokens of transactions as context. All on a
# Solid Queue fiber worker (fibers: 50), so every job is picked up at once.
class Ai::AsyncGpuMerchantsLiveTest < ActiveSupport::TestCase
  include AsyncSpikeHelper

  self.use_transactional_tests = false

  MERCHANT_JOBS  = Integer(ENV.fetch("SPIKE_MERCHANT_JOBS", "8"))
  MERCHANT_BATCH = Integer(ENV.fetch("SPIKE_MERCHANT_BATCH", "25"))
  CHAT_AFTER     = Integer(ENV.fetch("SPIKE_CHAT_AFTER", "20"))

  DESCRIPTIONS = [
    "AMZN Mktp US*2K4LM0PQ1", "NETFLIX.COM 866-579-7172 CA", "SPOTIFY P1A2B3C4D5 STOCKHOLM", "UBER *TRIP HELP.UBER.COM",
    "SQ *BLUE BOTTLE COFFEE", "TST* LOCAL DINER", "PAYROLL ACME CORP DIRECT DEP", "SHELL OIL 57444212500",
    "COSTCO WHSE #0421", "TRADER JOE S #552", "WHOLEFDS MKT 10237", "APPLE.COM/BILL 866-712-7753",
    "GOOGLE *YouTubePremium", "VENMO PAYMENT 1023456789", "ZELLE TO J SMITH", "CHEVRON 0091234",
    "STARBUCKS STORE 08812", "TARGET 00012345", "HOME DEPOT #6512", "COMCAST CABLE COMM",
    "PG&E WEB ONLINE", "DOORDASH*CHIPOTLE", "LYFT *RIDE TUE 8PM", "AIRBNB * HMQ2X4Z",
    "DELTA AIR 0062345678901", "CVS/PHARMACY #04512", "WALGREENS #3321", "ATM WITHDRAWAL 1234 MAIN ST",
    "PLANET FITNESS CLUB FEE", "GEICO AUTO PAY", "ADOBE *CREATIVE CLOUD", "DROPBOX*7K2L9M",
    "CHECK 1043", "LAUNDROMAT 24HR", "IKEA US EAST 211", "BEST BUY 00004321", "PATREON* MEMBERSHIP",
    "HULU 877-8244858", "DISNEY PLUS", "STEAMGAMES.COM 4259522985"
  ].freeze

  class MerchantChatJob < ApplicationJob
    self.queue_adapter = :solid_queue if defined?(SolidQueue)   # loaded with SPIKE_ASYNC=1

    def perform(kind, index, nonce)
      record = { kind:, picked: AsyncSpikeHelper.clock }
      lane = kind == "chat" ? :interactive : :prompt
      Ai::Transport::SlotInstrumenter.with_lane(lane) do
        kind == "chat" ? Ai::AsyncGpuMerchantsLiveTest.chat(record, nonce) : Ai::AsyncGpuMerchantsLiveTest.detect(record, index)
      end
    rescue => e
      record[:error] = "#{e.class}: #{e.message.truncate(120)}"
    ensure
      record[:finished] = AsyncSpikeHelper.clock
      AsyncSpikeHelper::RESULTS << record
    end
  end

  class SidekiqMerchantChatJob < MerchantChatJob
    self.queue_adapter = :sidekiq
  end

  # Two Solid Queue workers sharing llama.cpp through Solid Queue's own
  # concurrency control: a semaphore row per key in the database, so it holds
  # across workers and processes. Merchant jobs share one key with room for
  # all but one of llama.cpp's slots; chat has its own key, so its place is
  # kept. Blocked jobs are released in priority, then arrival, order. The
  # semaphore expires after `duration` (3 minutes by default) so a crashed
  # worker can't hold it forever, so it has to outlast the longest call.
  class LimitedMerchantJob < MerchantChatJob
    limits_concurrency key: ->(*) { "llama-merchants" }, to: 3, duration: 30.minutes if respond_to?(:limits_concurrency)
  end

  class LimitedChatJob < MerchantChatJob
    limits_concurrency key: ->(*) { "llama-chat" }, to: 1, duration: 30.minutes if respond_to?(:limits_concurrency)
  end

  # Two worker processes, each with its own in-process slot (the plan's §11):
  # the job's worker is stood in for by its index, chat in the first.
  class SlotPerWorker
    def initialize(*slots) = @slots = slots
    def hold(lane, &) = @slots.fetch(ActiveSupport::IsolatedExecutionState[:spike_worker] || 0).hold(lane, &)
    def stats = @slots.map(&:stats)
  end

  class TwoWorkerJob < MerchantChatJob
    def perform(kind, index, nonce)
      ActiveSupport::IsolatedExecutionState[:spike_worker] = kind == "chat" ? 0 : index % 2
      super
    end
  end

  def self.detect(record, index)
    transactions = MERCHANT_BATCH.times.map { { id: "txn_#{index}_#{_1}", name: DESCRIPTIONS[(index * 7 + _1) % DESCRIPTIONS.size] } }
    record[:called] = AsyncSpikeHelper.clock
    begin
      result = Ai::Generations::DetectMerchants.new(transactions:, user_merchants: [ "Blue Bottle" ]).call(route: AsyncSpikeHelper.llama_route)
    rescue Ai::Spike::LaneSlot::Preempted
      # A chat took the slot: wait for it again (chat first), then resend.
      record[:preempted] = record[:preempted].to_i + 1
      retry
    end
    merchants = Array(result.value[:merchants])
    record[:answers] = merchants.size
    record[:named] = merchants.count { _1["business_name"].present? }
    record[:output_tokens] = result.usage&.output_tokens
  end

  # A chat turn with a few thousand tokens of context, as Sure's assistant
  # sends after a tool round. The nonce keeps llama.cpp from reusing a cached
  # prefix from an earlier run.
  def self.chat(record, nonce)
    history = 120.times.map { |i| "#{Date.new(2026, 10, 30) - i} #{DESCRIPTIONS[(i * 3) % DESCRIPTIONS.size]} -#{format('%.2f', 3 + (i * 7.31) % 140)}" }
    request = Ai::Transport::Base::ConverseRequest.new(
      model: AsyncSpikeHelper.llama_route.model, reasoning_effort: "none", max_tokens: 300,
      instructions: "Session #{nonce}. You are the assistant in a personal finance app. Answer from the transactions given, briefly.",
      messages: [
        Ai::Transport::Base::Message.new(role: :user, content: "My recent transactions:\n#{history.join("\n")}\n\nWhich of these are subscriptions, and roughly what do they cost me each month?")
      ]
    )
    record[:called] = AsyncSpikeHelper.clock
    turn = Ai::Transport.for(AsyncSpikeHelper.llama_route.endpoint).converse(request) { record[:first_chunk] ||= AsyncSpikeHelper.clock }
    record[:input_tokens] = turn.usage&.input_tokens
    record[:output_tokens] = turn.usage&.output_tokens
    record[:text] = turn.text.to_s.squish.truncate(100)
  end

  setup do
    skip "live only: SPIKE_ASYNC=1 and SPIKE_LLAMA_CPP_URL" unless ENV["SPIKE_ASYNC"] == "1" && ENV["SPIKE_LLAMA_CPP_URL"].present?
    WebMock.disable!
    RESULTS.clear
  end

  teardown do
    WebMock.enable!
    Ai::Transport::SlotInstrumenter.slots = nil
  end

  test "chat_alone: the chat with nothing else running" do
    run_scenario("chat_alone", merchant_jobs: 0)
  end

  test "merchants_alone: the merchant jobs with no chat" do
    run_scenario("merchants_alone", chat: false)
  end

  test "no_drain: every call sent at once; llama.cpp queues what its slots can't take" do
    run_scenario("no_drain")
  end

  test "drain: no more calls than llama.cpp's slots, chat first in Sure's queue" do
    run_scenario("drain", slot: Ai::Spike::LaneSlot.new(llama_slots))
  end

  test "drain_reserve: as drain, with one slot kept for chat" do
    run_scenario("drain_reserve", slot: Ai::Spike::LaneSlot.new(llama_slots, reserved: 1))
  end

  test "drain_reserve_pause: as drain_reserve, and no merchant call starts while the chat runs" do
    run_scenario("drain_reserve_pause", slot: Ai::Spike::LaneSlot.new(llama_slots, reserved: 1, pause: true))
  end

  test "drain_pause: no slot kept, but no merchant call starts once the chat waits" do
    run_scenario("drain_pause", slot: Ai::Spike::LaneSlot.new(llama_slots, pause: true))
  end

  # One slot, MTP on (the default): a chat that finds the slot taken can
  # interrupt the merchant call, which waits behind the chat and is sent again.
  test "preempt: one slot, a chat interrupts the running merchant call" do
    run_scenario("preempt", slot: Ai::Spike::LaneSlot.new(llama_slots, preempt: true))
  end

  # How long one merchant call takes at each batch size, nothing else
  # running: on one slot, the longest a chat can wait behind it.
  test "call_length: merchant calls of 25, 10 and 5 transactions, one at a time" do
    total = Integer(ENV.fetch("SPIKE_CALL_TOTAL", "50"))
    ENV.fetch("SPIKE_CALL_SIZES", "25,10,5").split(",").map(&:to_i).each do |size|
      calls = (total / size).times.map do |index|
        record = {}
        transactions = size.times.map { { id: "txn_#{index}_#{_1}", name: DESCRIPTIONS[(index * size + _1) % DESCRIPTIONS.size] } }
        started = clock
        result = Ai::Generations::DetectMerchants.new(transactions:, user_merchants: [ "Blue Bottle" ]).call(route: AsyncSpikeHelper.llama_route)
        merchants = Array(result.value[:merchants])
        record.merge(s: (clock - started).round(1), out: result.usage&.output_tokens, in: result.usage&.input_tokens,
                     answered: merchants.size, named: merchants.count { _1["business_name"].present? })
      end
      seconds = calls.map { _1[:s] }
      puts "\n  #{{ batch: size, calls: calls.size, call_s: { min: seconds.min, median: seconds.sort[seconds.size / 2], max: seconds.max },
                    total_s: seconds.sum.round(1), transactions_per_min: (size * calls.size * 60 / seconds.sum).round(1),
                    tokens: { in: calls.sum { _1[:in].to_i }, out: calls.sum { _1[:out].to_i } },
                    answered: "#{calls.sum { _1[:answered] }}/#{size * calls.size}", named: calls.sum { _1[:named] } }.inspect}"
    end
  end

  # Sidekiq, the plan's runner: the slot in RubyLLM as above, and strict
  # queue order (chat's queue first). Threads, not fibers, so a job waiting
  # at the slot holds a thread.
  test "sidekiq_one_capsule: 4 AI threads, strict queue order, slot with one kept for chat" do
    slot = Ai::Spike::LaneSlot.new(llama_slots, reserved: 1)
    with_sidekiq(prompt: { threads: llama_slots, queues: %w[spike_ai_interactive spike_ai_prompt] }) do
      run_scenario("sidekiq_one_capsule", slot:, runner: :none) { |kind| SidekiqMerchantChatJob.set(queue: kind == "chat" ? "spike_ai_interactive" : "spike_ai_prompt") }
    end
  end

  test "sidekiq_chat_capsule: a 1-thread capsule for chat, 3 threads for the prompt lane, same slot" do
    slot = Ai::Spike::LaneSlot.new(llama_slots, reserved: 1)
    with_sidekiq(prompt: { threads: llama_slots - 1, queues: %w[spike_ai_prompt] }, chat: { threads: 1, queues: %w[spike_ai_interactive] }) do
      run_scenario("sidekiq_chat_capsule", slot:, runner: :none) { |kind| SidekiqMerchantChatJob.set(queue: kind == "chat" ? "spike_ai_interactive" : "spike_ai_prompt") }
    end
  end

  test "two_workers_slot_each: two workers, each with its own in-process slot (4, one kept for chat)" do
    slot = SlotPerWorker.new(Ai::Spike::LaneSlot.new(llama_slots, reserved: 1), Ai::Spike::LaneSlot.new(llama_slots, reserved: 1))
    run_scenario("two_workers_slot_each", slot:, workers: 2) { TwoWorkerJob.set(queue: QUEUE) }
  end

  test "two_workers_limits_concurrency: two workers, Solid Queue's database semaphore instead of a slot" do
    LimitedMerchantJob.concurrency_limit = llama_slots - 1
    run_scenario("two_workers_limits_concurrency", workers: 2) do |kind|
      kind == "chat" ? LimitedChatJob.set(queue: QUEUE, priority: 0) : LimitedMerchantJob.set(queue: QUEUE, priority: 10)
    end
  end

  private
    # Sidekiq inside this process: one capsule per entry, each with its own
    # threads and strictly ordered queues.
    def with_sidekiq(prompt:, chat: nil)
      require "sidekiq/api"
      [ *prompt[:queues], *chat&.dig(:queues) ].each { Sidekiq::Queue.new(_1).clear }
      instance = Sidekiq.configure_embed do |config|
        config.queues = prompt[:queues]
        config.concurrency = prompt[:threads]
        config.logger.level = Logger::WARN
        if chat
          config.capsule("chat") do |capsule|
            capsule.queues = chat[:queues]
            capsule.concurrency = chat[:threads]
          end
        end
      end
      instance.run
      yield
    ensure
      instance&.stop
    end

    # total_slots from llama-server's /props: how many requests it decodes at once.
    def llama_slots
      uri = URI(ENV.fetch("SPIKE_LLAMA_CPP_URL").delete_suffix("/v1") + "/props")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{ENV['SPIKE_LLAMA_CPP_API_KEY']}" if ENV["SPIKE_LLAMA_CPP_API_KEY"].present?
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { _1.request(request) }
      JSON.parse(response.body).fetch("total_slots")
    end

    # Most requests at llama.cpp at once, from their start and finish times.
    def peak(intervals)
      intervals.flat_map { [ [ _1[:start], 1 ], [ _1[:finish], -1 ] ] }.sort.reduce([ 0, 0 ]) { |(now, most), (_, step)| [ now + step, [ most, now + step ].max ] }.last
    end

    def with_runner(runner, workers, &)
      return yield if runner == :none

      with_solid_queue(fibers: 50, workers:, &)
    end

    # The block returns the configured job for a kind ("chat" or "merchants").
    def run_scenario(name, merchant_jobs: MERCHANT_JOBS, chat: true, slot: nil, runner: :solid_queue, workers: 1, &job_for)
      job_for ||= ->(_kind) { MerchantChatJob.set(queue: QUEUE) }
      Ai::Transport::SlotInstrumenter.slots = { URI(ENV.fetch("SPIKE_LLAMA_CPP_URL")).host => slot } if slot
      nonce = SecureRandom.hex(4)
      requests = Thread::Queue.new   # each HTTP request RubyLLM sent: lane, start, finish (after any wait for the slot)
      subscriber = ActiveSupport::Notifications.monotonic_subscribe("request.ruby_llm") do |_name, start, finish, _id, _payload|
        requests << { lane: Ai::Transport::SlotInstrumenter.lane, start:, finish: }
      end
      with_runner(runner, workers) do
        started = clock
        merchant_jobs.times { job_for.call("merchants").perform_later("merchants", _1, nonce) }
        if chat
          sleep CHAT_AFTER if merchant_jobs.positive?
          chat_enqueued = clock
          job_for.call("chat").perform_later("chat", 0, nonce)
        end
        results = (merchant_jobs + (chat ? 1 : 0)).times.filter_map { RESULTS.pop(timeout: 3600) }

        sent = []
        sent << requests.pop until requests.empty?
        chat_request = sent.find { _1[:lane] == :interactive }
        chat_record = results.find { _1[:kind] == "chat" }
        merchants = results.select { _1[:kind] == "merchants" }
        summary = { setup: name, llama_slots: llama_slots, slot: slot && slot.class.name.demodulize, workers: }
        if merchants.any?
          summary[:merchants_done_s] = (merchants.map { _1[:finished] }.max - started).round(1)
          summary[:merchant_request_s] = sent.reject { _1[:lane] == :interactive }.map { (_1[:finish] - _1[:start]).round(1) }.minmax
          summary[:peak_at_llama] = { merchants: peak(sent.reject { _1[:lane] == :interactive }), all: peak(sent) }
          summary[:merchant_answers] = "#{merchants.sum { _1[:answers].to_i }}/#{merchants.size * MERCHANT_BATCH}, named #{merchants.sum { _1[:named].to_i }}"
          summary[:merchant_output_tokens] = merchants.sum { _1[:output_tokens].to_i }
          summary[:merchant_preempted] = merchants.sum { _1[:preempted].to_i }
        end
        if chat_record
          first = chat_record[:first_chunk]
          summary[:chat_first_chunk_s] = first && (first - chat_enqueued).round(1)
          summary[:chat_done_s] = (chat_record[:finished] - chat_enqueued).round(1)
          summary[:chat_tokens] = "#{chat_record[:input_tokens]} in, #{chat_record[:output_tokens]} out"
          summary[:chat_decode_tok_s] = (chat_record[:output_tokens].to_f / (chat_record[:finished] - first)).round(1) if first && chat_record[:output_tokens].to_i.positive?
          in_flight = sent.find { _1[:lane] != :interactive && _1[:start] <= chat_enqueued && _1[:finish] >= chat_enqueued }
          summary[:call_in_flight_at_chat] = "had run #{(chat_enqueued - in_flight[:start]).round(1)} of #{(in_flight[:finish] - in_flight[:start]).round(1)} s" if in_flight
          if chat_request
            summary[:chat_sent_after_s] = (chat_request[:start] - chat_enqueued).round(1)
            summary[:merchant_requests_at_llama_during_chat] = sent.count { _1[:lane] != :interactive && _1[:finish] > chat_request[:start] && _1[:start] < chat_request[:finish] }
          end
          summary[:chat_text] = chat_record[:text]
        end
        summary[:errors] = results.filter_map { _1[:error] }.tally
        summary[:slot_stats] = slot&.stats
        puts "\n  #{summary.inspect}"
        assert_equal merchant_jobs + (chat ? 1 : 0), results.size
      end
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end
end
