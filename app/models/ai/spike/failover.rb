# Spike: section 5.4's failover and down marks, run against a gateway (one
# endpoint and key in front of many models, as OpenRouter, Vercel AI Gateway
# and Bedrock are) as well as a local server, under three marking rules:
#
# - :plan      section 5.4 as written. A timeout or 5xx marks the server
#              (host and port), a 429 or 401 the key, and failover moves
#              only to a route on a different server.
# - :response  the server only when no HTTP response came back
#              (Unreachable, which includes a connect timeout); a 401 the
#              key; a read timeout, 5xx or 429 only that model on that key.
#              Failover may stay on the same server.
# - :location  :plan for a local endpoint (one process: when it fails, all
#              of it fails) and :response for a cloud one.
#
# Escalation (InvalidOutput, ContextTooLong) is the same under every rule:
# no mark, next route on any server. max_moves is section 5.4's "at most
# once".
class Ai::Spike::Failover
  RULES = %i[plan response location].freeze
  DOWN_FOR = 60.seconds
  ESCALATE = [ Ai::Error::InvalidOutput, Ai::Error::ContextTooLong ].freeze
  FAIL_OVER = [ Ai::Error::Timeout, Ai::Error::Upstream, Ai::Error::RateLimited, Ai::Error::Unreachable, Ai::Error::Unauthorized ].freeze

  Attempt = Data.define(:route, :error, :mark)
  Outcome = Data.define(:route, :result, :attempts, :skipped)

  attr_reader :marks

  def initialize(rule:, max_moves: 1, marks: ActiveSupport::Cache::MemoryStore.new)
    raise ArgumentError, "unknown rule #{rule}" unless RULES.include?(rule)

    @rule, @max_moves, @marks = rule, max_moves, marks
  end

  # Yields each route tried. Returns an Outcome, or raises the last error.
  def run(routes)
    skipped, candidates = routes.partition { down?(_1) }
    raise Ai::Error::Unavailable.new(:all_routes_down) if candidates.empty?

    attempts = []
    route = candidates.first
    loop do
      return Outcome.new(route:, result: yield(route), attempts:, skipped:)
    rescue *FAIL_OVER, *ESCALATE => e
      attempts << Attempt.new(route:, error: e.class.name.demodulize, mark: mark(route, e))
      raise if attempts.size > @max_moves

      route = next_route(candidates, after: route, error: e) or raise
    end
  end

  def down?(route) = %i[server key model].any? { @marks.exist?(mark_key(_1, route)) }

  private
    def next_route(candidates, after:, error:)
      rest = candidates.drop(candidates.index(after) + 1).reject { down?(_1) }
      return rest.first if escalation?(error) || !whole_server?(after)

      rest.find { server(_1) != server(after) }
    end

    def mark(route, error)
      return if escalation?(error)

      scope = case error
      when Ai::Error::Unreachable then :server
      when Ai::Error::Unauthorized then :key
      when Ai::Error::RateLimited then whole_server?(route) ? :key : :model
      else whole_server?(route) ? :server : :model   # Timeout, Upstream
      end
      @marks.write(mark_key(scope, route), error.class.name.demodulize, expires_in: DOWN_FOR)
      scope
    end

    def whole_server?(route) = @rule == :plan || (@rule == :location && route.endpoint.local?)
    def escalation?(error) = ESCALATE.any? { error.is_a?(_1) }

    def server(route)
      uri = URI(route.endpoint.base_url)
      "#{uri.host}:#{uri.port}"
    end

    def mark_key(scope, route)
      key = Digest::SHA256.hexdigest(route.endpoint.api_key.to_s).first(8)
      case scope
      when :server then "ai:down:server:#{server(route)}"
      when :key then "ai:down:key:#{server(route)}:#{key}"
      when :model then "ai:down:model:#{server(route)}:#{key}:#{route.model.name}"
      end
    end
end
