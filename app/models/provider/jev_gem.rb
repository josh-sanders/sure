# Spike: Provider::Jev with its wire code (request, retries, response
# parsing and validation) replaced by the ruby_decision_model gem, 0.3.0.
# Everything above the wire stays Sure's: the fan-out, the category
# criteria, the opt-out sentinel and the confidence rules.
class Provider::JevGem < Provider::Jev
  # The gem appends a fixed path to a base URL. Sure stores the whole URL,
  # and every gateway takes the same body, so one provider posts to it as
  # given. OpenRouter reports a cost per request; TypeSafe sends none.
  class Endpoint < RubyDecisionModel::Providers::SystemOne
    def endpoint_path = ""
    def reports_cost? = true
  end

  # transport: a callable (url:, headers:, body:) -> [status, body, headers].
  # The default keeps Sure's TLS settings, which the gem's Net::HTTP lacks.
  def initialize(api_key, transport: nil, **)
    super(api_key, **)
    @transport = transport
  end

  private
    def decide!(state:, questions:, model: "")
      raise Error, "No questions provided" if questions.blank?

      questions = questions.transform_keys(&:to_s).transform_values(&:deep_stringify_keys)
      questions.each { |key, question| validate_question!(key, question) }

      response = gem_client(model.presence || @default_model).ask(state:, questions:)
      decision_set(response.answers, model: response.model, usage: response.usage)
    rescue RubyDecisionModel::MissingAnswers => e
      raise Error, e.message
    rescue RubyDecisionModel::InvalidResponse => e
      # The gem rejects the whole response for one malformed answer; Sure
      # withholds just that answer. Only the message tells the cases apart,
      # and the request's usage is lost with the response.
      raise Error, e.message unless e.message.start_with?("malformed answer fields")

      decision_set(e.answers, model: nil, usage: nil)
    rescue RubyDecisionModel::Error => e
      raise Error, e.message
    end

    def decision_set(answers, model:, usage:)
      ClassificationConcept::DecisionSet.new(
        decisions: answers.to_h { |key, answer| [ key, decision_from(key, answer) ] }, model:,
        usage: usage ? { "input_tokens" => usage.input_tokens.to_i, "output_tokens" => usage.output_tokens.to_i,
                         "total_tokens" => usage.input_tokens.to_i + usage.output_tokens.to_i, "cost" => usage.cost }.compact : {}
      )
    end

    def decision_from(key, answer)
      value = answer.public_send(answer.type)
      ClassificationConcept::Decision.new(
        key:, type: answer.type, value:, probabilities: answer.probabilities.presence,
        confidence: confidence_for(answer.type, value, answer.respond_to?(:confidence) ? answer.confidence : nil)
      )
    end

    # One client per model: the gem fixes the model when the client is built.
    def gem_client(model)
      @gem_clients ||= Concurrent::Map.new
      @gem_clients.compute_if_absent(model) do
        RubyDecisionModel::Client.new(
          provider: Endpoint.new(api_key:, base_url: @endpoint), model:,
          timeout: ENV.fetch("JEV_REQUEST_TIMEOUT", 30).to_i,
          retry: { max_retries: 3, total_timeout: 60.0 },
          transport: @transport || faraday_transport
        )
      end
    end

    def faraday_transport
      connection = Faraday.new(ssl: self.class.faraday_ssl_options) { |f| f.options.open_timeout = 5; f.options.timeout = ENV.fetch("JEV_REQUEST_TIMEOUT", 30).to_i }
      ->(url:, headers:, body:) { connection.post(url, body, headers).then { [ _1.status, _1.body, _1.headers.to_h ] } }
    end
end
