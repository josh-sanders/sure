require_relative "async_spike_helper"

# Spike, step 3: does Sure's AI code cooperate with a fiber reactor? A fiber
# worker runs many jobs on one thread, so a call that blocks the thread
# instead of yielding to the reactor stalls every job in that worker. Each
# test runs 20 calls concurrently in one Sync block against the stub provider
# (1 s per answer): about 1 s means the calls overlapped, about 20 s means
# each blocked the others. Run with SPIKE_ASYNC=1, and with SPIKE_ISOLATION
# set to fiber, then thread, for the Current test.
class Ai::AsyncFiberCompatLiveTest < ActiveSupport::TestCase
  include AsyncSpikeHelper

  self.use_transactional_tests = false

  CALLS = 20
  DELAY = 1

  class SpikeCurrent < ActiveSupport::CurrentAttributes
    attribute :family_id
  end

  setup do
    skip "live only: SPIKE_ASYNC=1" unless ENV["SPIKE_ASYNC"] == "1"
    require "async"
    WebMock.disable!
  end

  teardown do
    WebMock.enable!
    Ai::Transport::RubyLlmAdapter.faraday_adapter = nil
  end

  def concurrently(count = CALLS, &block)
    started = clock
    results = Sync { |task| count.times.map { |i| task.async { block.call(i) } }.map(&:wait) }
    [ results, (clock - started).round(2) ]
  end

  def report(name, **values) = puts("\n  #{name}: #{values.inspect}")

  def generate_concurrently(hand_written: false)
    with_stub_provider(delay: DELAY) do |base_url, stats|
      route = stub_route(base_url)
      results, wall = concurrently { bill_setup.call(route:, hand_written:).value[:amount] }
      [ results.uniq, wall, stats.call["peak"] ]
    end
  end

  test "RubyLLM generate on the default net_http adapter yields to the reactor" do
    amounts, wall, peak = generate_concurrently
    report("ruby_llm net_http", wall_s: wall, peak_in_flight: peak, amounts:)
    assert_equal [ 15.49 ], amounts
    assert_operator wall, :<, DELAY * 3
  end

  test "RubyLLM generate on the async_http adapter" do
    require "async/http/faraday"
    Ai::Transport::RubyLlmAdapter.faraday_adapter = :async_http
    amounts, wall, peak = generate_concurrently
    report("ruby_llm async_http", wall_s: wall, peak_in_flight: peak, amounts:)
    assert_equal [ 15.49 ], amounts
  end

  test "the hand-written transport (ruby-openai on Faraday) yields to the reactor" do
    amounts, wall, peak = generate_concurrently(hand_written: true)
    report("hand-written ruby-openai", wall_s: wall, peak_in_flight: peak, amounts:)
    assert_equal [ 15.49 ], amounts
  end

  test "streamed chat: 20 conversations stream side by side" do
    with_stub_provider(delay: DELAY) do |base_url, stats|
      route = stub_route(base_url)
      request = Ai::Transport::Base::ConverseRequest.new(model: route.model, instructions: "Be brief.",
                                                         messages: [ Ai::Transport::Base::Message.new(role: :user, content: "When is Netflix due?") ])
      started = clock
      results, wall = concurrently do
        first = nil
        turn = Ai::Transport.for(route.endpoint).converse(request) { first ||= clock }
        [ (first - started).round(2), turn.text ]
      end
      report "streamed chat", wall_s: wall, first_chunk_s: results.map(&:first).minmax, texts: results.map(&:last).uniq, peak_in_flight: stats.call["peak"]
      assert_operator results.map(&:first).max, :<, DELAY
    end
  end

  # Jev fans one batch out on an 8-thread pool (Provider::Jev#in_parallel)
  # and waits on futures. Inside a fiber worker, does the wait block the
  # reactor? 10 batches of 8 requests at once.
  test "Jev's thread pool inside fibers" do
    with_stub_provider(delay: DELAY) do |base_url, stats|
      jev = Provider::Jev.new("stub", endpoint: base_url.sub("/v1", "/decisions"), concurrency: 8)
      uri = URI(base_url.sub("/v1", "/decisions"))
      results, wall = concurrently(10) do
        jev.send(:in_parallel, 1..8) { Net::HTTP.post(uri, "{}", "Content-Type" => "application/json").code }
      end
      report "jev pool in fibers", wall_s: wall, codes: results.flatten.tally, peak_in_flight: stats.call["peak"]
      assert_equal({ "200" => 80 }, results.flatten.tally)
    end
  end

  # Current (and every CurrentAttributes) is per thread unless the app runs
  # on fiber isolation. Two jobs in one worker, one family each.
  test "Current attributes across two fibers" do
    seen, = concurrently(2) do |i|
      SpikeCurrent.family_id = i
      sleep 0.1
      SpikeCurrent.family_id
    end
    level = ActiveSupport::IsolatedExecutionState.isolation_level
    report "current attributes", isolation: level, set: [ 0, 1 ], read_back: seen
    assert_equal(level == :fiber ? [ 0, 1 ] : [ 1, 1 ], seen)
  end

  # Sure's pool is RAILS_MAX_THREADS (3). Fifty fibers querying around a
  # 0.5 s wait: Rails 8.1 returns the connection after each query.
  test "fifty fibers share a pool of three when they don't hold a connection across a wait" do
    errors, wall = concurrently(50) do
      Family.limit(1).pluck(:id)
      sleep 0.5
      Family.limit(1).pluck(:id)
      nil
    rescue => e
      e.class.name
    end
    report "pool, no transaction", wall_s: wall, pool: ActiveRecord::Base.connection_pool.size, errors: errors.compact.tally
    assert_empty errors.compact
  end

  # The page's caveat: a transaction held across an AI call keeps the
  # connection. Nine fibers, each holding one for 2 s, on a pool of three:
  # they run three at a time, and the last three wait 4 s for a connection,
  # just inside the 5 s checkout timeout.
  test "a transaction held across a wait holds the connection" do
    errors, wall = concurrently(9) do
      Family.transaction do
        Family.limit(1).pluck(:id)
        sleep 2
      end
      nil
    rescue => e
      e.class.name
    end
    report "pool, transaction across the wait", wall_s: wall, pool: ActiveRecord::Base.connection_pool.size,
           checkout_timeout: ActiveRecord::Base.connection_pool.checkout_timeout, errors: errors.compact.tally
    assert_operator wall, :>=, 6, "three at a time"
  end

  # Page rendering for PDF import: ruby-vips calls libvips in the same
  # thread; pdftoppm is a child process. A ticker fiber wakes every 50 ms
  # while the pages render; its longest gap is how long the reactor stalled.
  # Both statements' pages, at the 150 dpi Sure renders.
  test "rendering PDF pages: how long each renderer stalls the reactor" do
    pdfs = %w[impact_scanned bac_ocr].map { file_fixture("statements/#{_1}.pdf").binread }
    stalls = %i[vips pdftoppm].index_with do |renderer|
      gaps = []
      started = clock
      Sync do |task|
        ticker = task.async do
          last = clock
          loop do
            sleep 0.05
            now = clock
            gaps << now - last
            last = now
          end
        end
        task.async { pdfs.each { Pdf::PageImages.pages(_1, renderer:) } }.wait
        ticker.stop
      end
      { render_s: (clock - started).round(2), longest_stall_s: (gaps.max - 0.05).round(2) }
    end
    report "render stall", **stalls
    assert_operator stalls[:pdftoppm][:longest_stall_s], :<, 0.05, "a child process doesn't hold the thread"
  end
end
