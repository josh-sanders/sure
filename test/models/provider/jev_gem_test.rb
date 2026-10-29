require "test_helper"
require_relative "jev_test"

# Spike: Sure's Provider::Jev tests, run against the provider backed by the
# ruby_decision_model gem. Tests that build Provider::Jev themselves still
# test the hand-written class; the rest use @provider. The four overridden
# below are where the gem differs: it drops a malformed answer instead of
# handing it over with a confidence of 0, so the answer is withheld rather
# than present and unconfident. Nothing is applied either way.
class Provider::JevGemTest < Provider::JevTest
  setup do
    @provider = Provider::JevGem.new("test_api_key")
    RubyDecisionModel::Client.any_instance.stubs(:sleep)
  end

  # ActiveSupport's `test` refuses a name the parent already defines.
  def self.override(name, &) = define_method("test_#{name.gsub(/\s+/, "_")}", &)

  def answer_body(answer) = { status: 200, body: { "answers" => { "q" => answer } }.to_json, headers: { "Content-Type" => "application/json" } }

  override "treats a choice with no reported confidence as maximally unconfident" do
    stub_request(:post, ENDPOINT).to_return(answer_body({ "type" => "choice", "choice" => "Coffee" }))
    response = @provider.decide(state: "x", questions: { q: { type: "choice", instructions: "?", criteria: { "Coffee" => nil } } })

    assert response.success?
    assert_nil response.data[:q], "withheld, not present with confidence 0"
  end

  override "does not apply noul arithmetic to a score missing its confidence" do
    stub_request(:post, ENDPOINT).to_return(answer_body({ "type" => "score", "score" => 1.92 }))
    response = @provider.decide(state: "x", questions: { q: { type: "score", instructions: "?", criteria: %w[a b c] } })

    assert_nil response.data[:q]
  end

  override "survives a noul answer whose probability is not a number" do
    stub_request(:post, ENDPOINT).to_return(answer_body({ "type" => "noul", "noul" => "not-a-number" }))
    response = @provider.decide(state: "x", questions: { q: { type: "noul", instructions: "?" } })

    assert response.success?
    assert_nil response.data[:q]
  end

  override "surfaces a malformed response as a provider error" do
    stub_request(:post, ENDPOINT).to_return(status: 200, body: { "nope" => true }.to_json, headers: { "Content-Type" => "application/json" })
    response = @provider.decide(state: "x", questions: { q: { type: "noul", instructions: "?" } })

    assert_not response.success?
    assert_kind_of Provider::Jev::Error, response.error
    assert_match "missing or wrong-type answers for: q", response.error.message
  end
end
