require_relative "async_spike_helper"

# Spike, step 1: many cloud calls at once. The plan runs AI jobs on Sidekiq's
# ai capsule, RAILS_AI_MAX_THREADS threads (default 1), so calls in flight are
# capped at workers × threads (§11). rubyllm.com/async offers fiber workers
# instead: Solid Queue 1.6+ with fibers: N, or Async::Job on Redis. For fibers:
# a waiting call costs a fiber, not a thread. Against: a second job backend
# beside Sidekiq, and isolation_level = :fiber for the whole app.
#
# 200 jobs, each one bill setup against a stub provider that answers after
# 2 s (stub_provider.rb), so the numbers measure the job runner, not a model.
# Each scenario runs alone (-n), in its own process, with the isolation level
# it needs (SPIKE_ISOLATION). RAILS_MAX_THREADS is Sure's default of 3, which
# is also the database pool.
class Ai::AsyncJobBackendsLiveTest < ActiveSupport::TestCase
  include AsyncSpikeHelper

  self.use_transactional_tests = false

  JOBS = 200
  DELAY = 2

  SCENARIOS = {
    "sidekiq_threads_5" => { backend: :sidekiq, concurrency: 5, isolation: :thread },
    "sidekiq_threads_50" => { backend: :sidekiq, concurrency: 50, isolation: :thread },
    "sidekiq_threads_200" => { backend: :sidekiq, concurrency: 200, isolation: :thread },
    "solid_queue_threads_50" => { backend: :solid_queue, threads: 50, isolation: :thread },
    "solid_queue_fibers_50" => { backend: :solid_queue, fibers: 50, isolation: :fiber },
    "solid_queue_fibers_200" => { backend: :solid_queue, fibers: 200, isolation: :fiber },
    "async_job" => { backend: :async_job, isolation: :fiber },
    # A provider that allows 20 requests in flight and answers 429 above it.
    "sidekiq_threads_50_limit_20" => { backend: :sidekiq, concurrency: 50, isolation: :thread, limit: 20, max_retries: 3 },
    "solid_queue_fibers_200_limit_20" => { backend: :solid_queue, fibers: 200, isolation: :fiber, limit: 20, max_retries: 3 },
    "async_job_limit_20" => { backend: :async_job, isolation: :fiber, limit: 20, max_retries: 3 }
  }.freeze

  setup do
    skip "live only: SPIKE_ASYNC=1" unless ENV["SPIKE_ASYNC"] == "1"
    WebMock.disable!
    RESULTS.clear
  end

  teardown do
    WebMock.enable!
  end

  SCENARIOS.each do |name, scenario|
    test "#{name}: #{JOBS} cloud calls of #{DELAY} s" do
      assert_equal scenario[:isolation], ActiveSupport::IsolatedExecutionState.isolation_level,
                   "run with SPIKE_ISOLATION=#{scenario[:isolation]}"

      summary = nil
      with_stub_provider(delay: DELAY, limit: scenario[:limit]) do |base_url, stats|
        sampler = Sampler.new
        sampler.run do
          send("run_on_#{scenario[:backend]}", scenario) do |job_class|
            started = clock
            ActiveJob.perform_all_later(JOBS.times.map { job_class.new(_1, base_url, scenario.fetch(:max_retries, 0)) })
            enqueued = clock
            results = JOBS.times.filter_map { RESULTS.pop(timeout: 300) }
            finished = clock
            summary = {
              scenario: name, completed: results.size, errors: results.filter_map { _1[:error] }.tally,
              enqueue_s: (enqueued - started).round(2), wall_s: (finished - started).round(1),
              threads_used: results.map { _1[:thread] }.uniq.size, fibers_used: results.map { _1[:fiber] }.uniq.size,
              provider: stats.call.slice("peak", "rate_limited")
            }
          end
        end
        summary.merge!(sampler.peaks)
      end

      puts "\n  #{summary.inspect}"
      assert_equal JOBS, summary[:completed]
    end
  end

  private
    def run_on_sidekiq(scenario)
      require "sidekiq/api"
      Sidekiq::Queue.new(QUEUE).clear
      instance = Sidekiq.configure_embed do |config|
        config.queues = [ QUEUE ]
        config.concurrency = scenario[:concurrency]
        config.logger.level = Logger::WARN
      end
      instance.run
      yield SidekiqJob
    ensure
      instance&.stop
    end

    def run_on_solid_queue(scenario, &)
      with_solid_queue(**scenario.slice(:threads, :fibers)) { yield SolidQueueJob }
    end

    def run_on_async_job(_scenario)
      path = URI(ENV.fetch("REDIS_URL")).path
      prefix = "spike-async-job-#{SecureRandom.hex(4)}"
      Rails.application.config.async_job.define_queue(QUEUE) do
        dequeue Async::Job::Processor::Redis, endpoint: Async::Redis::Endpoint.unix(path), prefix:
      end
      server = Thread.new do
        Sync do
          Rails.application.config.async_job.start(QUEUE)
          sleep
        end
      end
      yield AsyncJobJob
    ensure
      server&.kill&.join(5)
    end
end
