require_relative "spike_helper"
require_relative "statement_scoring"

# Spike: RubyLLM::Evaluation against Sure's own eval framework
# (app/models/eval, about 3,700 lines: datasets, runs, samples, reporters,
# Langfuse, rake evals:ci_regression), which the plan wires to prompt
# changes (O-B3). For RubyLLM's: a class and a dataset, model-graded
# correctness, Ruby assertions beside it, a JSON report with tokens and
# cost, and Minitest or Rake to run it. Against: its datasets are files, not
# the recorded production samples Sure's evals import, and its grader is
# another model call per case.
#
# Here: ExtractBankStatement on the two statements' text layers, extracted
# and graded by Gemini, with Sure's reconciliation check as an assertion.
class Ai::RubyLlmEvaluationLiveTest < ActiveSupport::TestCase
  include AiSpikeHelper
  include StatementScoring

  MODEL = "gemini-3.5-flash-lite".freeze

  # The grader failed the scan case although the extraction was right:
  # "0 transactions; opening balance nil and closing balance nil" didn't
  # "agree with" the reference wording. Model grading depends on how
  # perform phrases its output against the reference; the Ruby assertion
  # (reconciliation) passed on both.
  EXPECTED = [ [ "bac_text_layer", :passed, [ [ :correctness, true ] ] ], [ "scan_text_layer", :failed, [ [ :correctness, false ] ] ] ].freeze

  def self.endpoint = Ai::Spike::Presets.gemini(api_key: ENV.fetch("SPIKE_GEMINI_API_KEY", "gemini-key"), max_retries: 0)
  def self.route = Ai::Spike::Route.new(model: Ai::Spike::Model.new(endpoint:, name: MODEL, max_output_tokens: 4096))

  class StatementEvaluation < RubyLLM::Evaluation
    dataset [
      { name: "bac_text_layer", inputs: "bac_ocr",
        expected_output: "13 transactions; opening balance 40,000.00 and closing balance 44,079.83." },
      { name: "scan_text_layer", inputs: "impact_scanned",
        expected_output: "No transactions: the text layer is empty, so nothing can be read." }
    ]
    evaluator MODEL, provider: :openai, protocol: :chat_completions, assume_model_exists: true,
                     context: Ai::Transport.for(Ai::RubyLlmEvaluationLiveTest.endpoint).send(:ruby_llm_context)

    def perform(statement)
      text = Pdf::TextExtractor.pages(StatementScoring::FILES.join("#{statement}.pdf").binread).join("\n")
      generation = Ai::Generations::ExtractBankStatement.new(text:)
      value = generation.call(route: Ai::RubyLlmEvaluationLiveTest.route).value
      @checks = generation.checks(value)
      count = Array(value[:transactions]).count { _1["amount"].to_f.nonzero? }
      "#{count} transactions; opening balance #{value[:opening_balance].inspect} and closing balance #{value[:closing_balance].inspect}."
    end

    def assertions
      assert @checks.reconciles == (input == "bac_ocr"), "reconciles exactly when there's a statement to read"
    end
  end

  test "an evaluation of statement extraction, model-graded with a Ruby assertion (live)" do
    with_spike_cassette("features/evaluation") do
      @report = StatementEvaluation.run
    end

    rows = @report.trials.map { [ _1.test_case.name, _1.status, _1.evaluations.map { |e| [ e.name, e.passed? ] } ] }
    puts "\n  evaluation: #{rows.inspect} passed=#{@report.passed?} tokens=#{@report.tokens.to_h.inspect}\n#{@report}" if recording? || ENV["SPIKE_PRINT"]
    assert_equal EXPECTED, rows if defined?(EXPECTED)
  end
end
