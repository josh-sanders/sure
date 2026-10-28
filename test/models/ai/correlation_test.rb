require_relative "spike_helper"

# Section 10: the job's arguments are the source of the correlation id.
# Two ways to stamp it on every call: Sure's own .ai events, or RubyLLM's
# workflow context on its chat.ruby_llm events.
class Ai::CorrelationTest < ActiveSupport::TestCase
  include AiSpikeHelper

  class SpikeJob < ApplicationJob
    def perform(rule_run_id, approach)
      generation = Ai::Generations::SuggestBillSetup.new(charges: AiSpikeHelper::CHARGES, categories: AiSpikeHelper::CATEGORIES)
      route = Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint: Ai::Spike::Presets.lmstudio(json_mode: "auto"), name: "m"))
      case approach
      when :sure then Ai::Correlation.with("rule_run:#{rule_run_id}") { generation.call(route:) }
      when :ruby_llm then RubyLLM.workflow("bill_setup", id: "rule_run:#{rule_run_id}") { generation.call(route:) }
      end
    end
  end

  def subscribe(pattern)
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(pattern) { events << _1 }
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def ok = { status: 200, headers: { "Content-Type" => "application/json" }, body: {
    id: "c", choices: [ { index: 0, finish_reason: "stop", message: { role: "assistant", content: AiSpikeHelper::NETFLIX_JSON } } ],
    usage: { prompt_tokens: 400, completion_tokens: 100 } }.to_json }
  def mostly_null = ok.merge(body: JSON.parse(ok[:body]).deep_merge("choices" => [ { "message" => { "role" => "assistant", "content" => { name: "Netflix" }.to_json } } ]).to_json)
  def rate_limited = { status: 429, headers: { "Content-Type" => "application/json" }, body: { error: { message: "slow down" } }.to_json }

  test "Sure's events: one per call with correlation id, route, usage and Ai::Error class" do
    stub_request(:post, %r{lmstudio.test}).to_return(mostly_null, ok, rate_limited)

    events = subscribe(/\.ai\z/) do
      SpikeJob.perform_now(42, :sure)
      assert_raises(Ai::Error::RateLimited) { SpikeJob.perform_now(43, :sure) }
    end

    assert_equal %w[rule_run:42 rule_run:43], events.map { _1.payload[:correlation_id] }
    assert_equal "LM Studio", events.first.payload[:endpoint]
    assert_equal({ endpoint: "LM Studio", model: "m", json_mode: "auto" }, events.first.payload[:prompt][:metadata][:route])
    assert_equal 500 * 2, events.first.payload[:usage].input_tokens + events.first.payload[:usage].output_tokens, "both JSON-mode attempts summed"
    assert_equal [ nil, "Ai::Error::RateLimited" ], events.map { _1.payload[:error] }
  end

  test "RubyLLM's events: one per wire call, with the workflow id, but no route and the gem's own error class" do
    stub_request(:post, %r{lmstudio.test}).to_return(mostly_null, ok, rate_limited)

    events = subscribe("chat.ruby_llm") do
      SpikeJob.perform_now(42, :ruby_llm)
      assert_raises(Ai::Error::RateLimited) { SpikeJob.perform_now(43, :ruby_llm) }
    end

    assert_equal %w[rule_run:42 rule_run:42 rule_run:43], events.map { _1.payload[:workflow_id] }
    assert_equal [ 400, 400, nil ], events.map { _1.payload[:tokens]&.input }, "one event per JSON-mode attempt"
    assert_equal [ nil, nil, "RubyLLM::RateLimitError" ], events.map { _1.payload[:exception]&.first }
    refute events.first.payload.key?(:route), "the route (endpoint, model, overrides, prompt) is Sure's, not the gem's"
    assert_equal "openai", events.first.payload[:provider], "every compatible server reports as openai"
    assert events.first.payload[:input_messages].any? { _1.role == :system }, "the prompt is there"
  end

  test "the workflow id must be re-entered in each job: it is thread-local and gone after the block" do
    RubyLLM.workflow("bill_setup", id: "rule_run:1") { assert_equal "rule_run:1", RubyLLM::Support::Instrumentation.current_workflow[:workflow_id] }
    assert_nil RubyLLM::Support::Instrumentation.current_workflow
  end
end
