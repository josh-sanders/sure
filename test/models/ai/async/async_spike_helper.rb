require_relative "../spike_helper"

# The async spike (rubyllm.com/async): AI jobs on fiber workers against
# Sidekiq threads. Live only, with SPIKE_ASYNC=1 (config/application.rb loads
# Solid Queue and Async::Job then). The jobs run inside the test process, so
# these tests don't use transactions, and WebMock is off while they run.
module AsyncSpikeHelper
  include AiSpikeHelper

  QUEUE = "spike_async".freeze
  RESULTS = Thread::Queue.new

  # One AI job as the plan has it: load the input, make the call, save the
  # result. The two queries stand for the load and the save, so the job's
  # database use is counted without writing to fixtures.
  class BenchJob < ApplicationJob
    queue_as QUEUE

    def perform(index, base_url, max_retries)
      started = AsyncSpikeHelper.clock
      Family.limit(1).pluck(:id)
      error = begin
        AsyncSpikeHelper.bill_setup.call(route: AsyncSpikeHelper.stub_route(base_url, max_retries:))
        nil
      rescue => e
        e.class.name
      end
      Family.limit(1).pluck(:id)
      RESULTS << { index:, started:, finished: AsyncSpikeHelper.clock, error:, fiber: Fiber.current.object_id, thread: Thread.current.object_id }
    end
  end

  class SidekiqJob < BenchJob
    self.queue_adapter = :sidekiq
  end

  class SolidQueueJob < BenchJob
    self.queue_adapter = :solid_queue if defined?(SolidQueue)   # loaded with SPIKE_ASYNC=1
  end

  class AsyncJobJob < BenchJob
    self.queue_adapter = :async_job if defined?(Async::Job)
  end

  module_function

  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def bill_setup = Ai::Generations::SuggestBillSetup.new(charges: AiSpikeHelper::CHARGES, categories: AiSpikeHelper::CATEGORIES)

  def stub_route(base_url, max_retries: 0)
    endpoint = Ai::Spike::Endpoint.new(name: "Stub cloud", protocol: :compatible, preset: :openai_compatible, base_url:,
                                       api_key: "stub", json_mode: "strict", timeout_seconds: 60, max_retries:)
    Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint:, name: "stub-model", max_output_tokens: 512))
  end

  # The stub provider (stub_provider.rb), in its own process.
  def with_stub_provider(delay: 2, limit: nil)
    script = File.expand_path("stub_provider.rb", __dir__)
    io = IO.popen([ RbConfig.ruby, script, delay.to_s, *limit&.to_s ], "r")
    port = Integer(io.gets)
    yield "http://127.0.0.1:#{port}/v1", -> { JSON.parse(Net::HTTP.get(URI("http://127.0.0.1:#{port}/stats"))) }
  ensure
    if io
      Process.kill("TERM", io.pid) rescue nil
      io.close
    end
  end

  # A Solid Queue worker inside this process, on Solid Queue's tables in the
  # test database for the length of one test.
  def with_solid_queue(**pool)
    schema = Gem.loaded_specs["solid_queue"].full_gem_path + "/lib/generators/solid_queue/install/templates/db/queue_schema.rb"
    ActiveRecord::Migration.suppress_messages do
      eval(File.read(schema).sub(/define\(version: [\d_]+\)/, "define"), TOPLEVEL_BINDING, schema) # rubocop:disable Security/Eval
    end
    worker = SolidQueue::Worker.new(queues: QUEUE, polling_interval: 0.05, **pool)
    worker.start
    yield
  ensure
    worker&.stop
    connection = ActiveRecord::Base.connection
    connection.tables.grep(/\Asolid_queue_/).each { connection.drop_table(_1, force: :cascade) }
  end

  # Samples this process every 50 ms: resident memory, threads, the Active
  # Record pool, and the database's connections from any process.
  class Sampler
    def initialize
      @peaks = Hash.new(0)
      config = ActiveRecord::Base.connection_db_config.configuration_hash
      @pg = PG.connect(host: config[:host], port: config[:port], dbname: config[:database], user: config[:username])
      @baseline = connections
    end

    def run
      @thread = Thread.new do
        loop do
          sample
          sleep 0.05
        end
      end
      yield
    ensure
      @thread&.kill
      sample
      @pg.close
    end

    def peaks = @peaks.merge(db_connections_added: @peaks[:db_connections] - @baseline).except(:db_connections)

    private
      def connections = @pg.exec("SELECT count(*) FROM pg_stat_activity WHERE datname = current_database()").getvalue(0, 0).to_i - 1

      def sample
        stat = ActiveRecord::Base.connection_pool.stat
        {
          rss_mb: File.read("/proc/self/status")[/VmRSS:\s+(\d+)/, 1].to_i / 1024,
          threads: Thread.list.size,
          pool_connections: stat[:connections],
          pool_waiting: stat[:waiting],
          db_connections: connections
        }.each { |key, value| @peaks[key] = [ @peaks[key], value ].max }
      end
  end
end
