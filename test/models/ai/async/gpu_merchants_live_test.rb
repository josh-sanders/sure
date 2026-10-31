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

  def self.detect(record, index)
    transactions = MERCHANT_BATCH.times.map { { id: "txn_#{index}_#{_1}", name: DESCRIPTIONS[(index * 7 + _1) % DESCRIPTIONS.size] } }
    record[:called] = AsyncSpikeHelper.clock
    result = Ai::Generations::DetectMerchants.new(transactions:, user_merchants: [ "Blue Bottle" ]).call(route: AsyncSpikeHelper.llama_route)
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

  private
    # total_slots from llama-server's /props: how many requests it decodes at once.
    def llama_slots
      uri = URI(ENV.fetch("SPIKE_LLAMA_CPP_URL").delete_suffix("/v1") + "/props")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{ENV['SPIKE_LLAMA_CPP_API_KEY']}" if ENV["SPIKE_LLAMA_CPP_API_KEY"].present?
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { _1.request(request) }
      JSON.parse(response.body).fetch("total_slots")
    end

    def run_scenario(name, merchant_jobs: MERCHANT_JOBS, chat: true, slot: nil)
      Ai::Transport::SlotInstrumenter.slots = { URI(ENV.fetch("SPIKE_LLAMA_CPP_URL")).host => slot } if slot
      nonce = SecureRandom.hex(4)
      requests = Thread::Queue.new   # each HTTP request RubyLLM sent: lane, start, finish (after any wait for the slot)
      subscriber = ActiveSupport::Notifications.monotonic_subscribe("request.ruby_llm") do |_name, start, finish, _id, _payload|
        requests << { lane: Ai::Transport::SlotInstrumenter.lane, start:, finish: }
      end
      with_solid_queue(fibers: 50) do
        started = clock
        merchant_jobs.times { MerchantChatJob.set(queue: QUEUE).perform_later("merchants", _1, nonce) }
        if chat
          sleep CHAT_AFTER if merchant_jobs.positive?
          chat_enqueued = clock
          MerchantChatJob.set(queue: QUEUE).perform_later("chat", 0, nonce)
        end
        results = (merchant_jobs + (chat ? 1 : 0)).times.filter_map { RESULTS.pop(timeout: 3600) }

        sent = []
        sent << requests.pop until requests.empty?
        chat_request = sent.find { _1[:lane] == :interactive }
        chat_record = results.find { _1[:kind] == "chat" }
        merchants = results.select { _1[:kind] == "merchants" }
        summary = { setup: name, llama_slots: llama_slots, slot: slot && "#{slot.class.name.demodulize}" }
        if merchants.any?
          summary[:merchants_done_s] = (merchants.map { _1[:finished] }.max - started).round(1)
          summary[:merchant_request_s] = sent.reject { _1[:lane] == :interactive }.map { (_1[:finish] - _1[:start]).round(1) }.minmax
          summary[:merchant_answers] = "#{merchants.sum { _1[:answers].to_i }}/#{merchants.size * MERCHANT_BATCH}, named #{merchants.sum { _1[:named].to_i }}"
          summary[:merchant_output_tokens] = merchants.sum { _1[:output_tokens].to_i }
        end
        if chat_record
          first = chat_record[:first_chunk]
          summary[:chat_first_chunk_s] = first && (first - chat_enqueued).round(1)
          summary[:chat_done_s] = (chat_record[:finished] - chat_enqueued).round(1)
          summary[:chat_tokens] = "#{chat_record[:input_tokens]} in, #{chat_record[:output_tokens]} out"
          summary[:chat_decode_tok_s] = (chat_record[:output_tokens].to_f / (chat_record[:finished] - first)).round(1) if first && chat_record[:output_tokens].to_i.positive?
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
