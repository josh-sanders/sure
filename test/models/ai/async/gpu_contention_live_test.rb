require_relative "async_spike_helper"

# Spike, step 2b: chat and embeddings on one machine. llama.cpp's chat server
# (qwen3.6) and its embedding server (granite-embedding-small) run in two
# containers on the same host and CPUs, and neither knows about the other.
# The plan keys its slot by host without the port, so the two take turns,
# chat first (§11). Here the slot lives inside RubyLLM: every request a
# RubyLLM context makes passes through its instrumenter
# (Ai::Transport::SlotInstrumenter), which holds the host's slot in the job's
# lane. Nothing in the job or the transport call changes.
#
# A batch of embedding jobs (the prompt lane: 64 transaction texts each) is
# queued, then, 3 s later, one chat message. All on a Solid Queue fiber
# worker (fibers: 50).
class Ai::AsyncGpuContentionLiveTest < ActiveSupport::TestCase
  include AsyncSpikeHelper

  self.use_transactional_tests = false

  EMBED_JOBS = Integer(ENV.fetch("SPIKE_EMBED_JOBS", "60"))
  CHAT_AFTER = 3

  class ContentionJob < ApplicationJob
    self.queue_adapter = :solid_queue if defined?(SolidQueue)   # loaded with SPIKE_ASYNC=1

    def perform(kind, index)
      record = { kind:, called: AsyncSpikeHelper.clock }
      lane = kind == "chat" ? :interactive : :prompt
      Ai::Transport::SlotInstrumenter.with_lane(lane) do
        kind == "chat" ? AsyncSpikeHelper.stream_chat(record) : Ai::AsyncGpuContentionLiveTest.embed(index)
      end
    rescue => e
      record[:error] = "#{e.class}: #{e.message.truncate(120)}"
    ensure
      record[:finished] = AsyncSpikeHelper.clock
      AsyncSpikeHelper::RESULTS << record
    end
  end

  def self.embed(index)
    endpoint = Ai::Spike::Presets.llama_cpp_embed
    model = Ai::Spike::Model.new(endpoint:, name: "granite-embedding-small-english-r2", embedding_dimensions: 384)
    texts = 64.times.map { "#{Date.new(2026, 1, 1) + _1} NETFLIX.COM AUTOPAY #{index}-#{_1} 15.49 Entertainment subscription" }
    Ai::Transport::Compatible.new(endpoint).embed(texts, model:)
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
    run_scenario("chat_alone", embed_jobs: 0)
  end

  test "embed_alone: the embedding jobs with no chat" do
    run_scenario("embed_alone", chat: false)
  end

  test "no_slot: embeddings and chat at once, uncoordinated" do
    run_scenario("no_slot")
  end

  test "host_slot: one slot for the host, held inside RubyLLM, chat first" do
    host = URI(ENV.fetch("SPIKE_LLAMA_CPP_URL")).host
    Ai::Transport::SlotInstrumenter.slots = { host => Ai::Spike::LaneSlot.new(1) }
    run_scenario("host_slot")
  end

  private
    def run_scenario(name, embed_jobs: EMBED_JOBS, chat: true)
      with_solid_queue(fibers: 50) do
        started = clock
        embed_jobs.times { ContentionJob.set(queue: QUEUE).perform_later("embed", _1) }
        if chat
          sleep CHAT_AFTER if embed_jobs.positive?
          chat_enqueued = clock
          ContentionJob.set(queue: QUEUE).perform_later("chat", 0)
        end
        results = (embed_jobs + (chat ? 1 : 0)).times.filter_map { RESULTS.pop(timeout: 1800) }

        chat_record = results.find { _1[:kind] == "chat" }
        embeds = results.select { _1[:kind] == "embed" }
        summary = { setup: name, llama_parallel: ENV["SPIKE_LLAMA_PARALLEL"], embed_jobs: embeds.size }
        summary[:embed_done_s] = (embeds.map { _1[:finished] }.max - started).round(1) if embeds.any?
        summary[:embed_call_s] = embeds.map { (_1[:finished] - _1[:called]).round(2) }.minmax if embeds.any?
        if chat_record
          summary[:chat_first_chunk_s] = chat_record[:first_chunk] && (chat_record[:first_chunk] - chat_enqueued).round(2)
          summary[:chat_done_s] = (chat_record[:finished] - chat_enqueued).round(2)
          summary[:embeds_during_chat] = embeds.count { _1[:finished] > chat_record[:called] && _1[:called] < chat_record[:finished] }
        end
        summary[:errors] = results.filter_map { _1[:error] }.tally
        summary[:slot] = Ai::Transport::SlotInstrumenter.slots&.values&.first&.stats
        puts "\n  #{summary.inspect}"
        assert_equal embed_jobs + (chat ? 1 : 0), results.size
      end
    end
end
