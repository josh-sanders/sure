require_relative "../ai/spike_helper"

# Spike: the gem-backed Jev provider live on OpenCode Zen's gateway
# (jev-1.13-free, the anonymous key "public"), recorded, through Sure's own
# auto_categorize fan-out.
class Provider::JevGemLiveTest < ActiveSupport::TestCase
  include AiSpikeHelper

  ENDPOINT = "https://opencode.ai/zen/v1/systemone".freeze
  MODEL = "jev-1.13-free".freeze

  def categories = %w[Entertainment Utilities Groceries Transport].each_with_index.map { |name, i| { id: "c#{i}", name:, parent_id: nil } }

  def transactions
    { "t1" => [ "NETFLIX.COM AUTOPAY", "15.49" ], "t2" => [ "PG&E WEB ONLINE PAYMENT", "112.30" ],
      "t3" => [ "WHOLE FOODS MARKET #10233", "86.12" ], "t4" => [ "UBER *TRIP HELP.UBER.COM", "23.80" ] }
      .map { |id, (description, amount)| { id:, description:, amount:, classification: "expense" } }
  end

  test "auto_categorize over the gem, fanned out by Sure (live)" do
    provider = Provider::JevGem.new("public", endpoint: ENDPOINT, model: MODEL, concurrency: 4)
    with_spike_cassette("jev/gem_auto_categorize", match: %i[method uri body]) do
      @response = provider.auto_categorize(transactions:, user_categories: categories)
    end

    assert @response.success?, @response.error&.message
    assert_equal({ "t1" => "Entertainment", "t2" => "Utilities", "t3" => "Groceries", "t4" => "Transport" },
                 @response.data.to_h { [ _1.transaction_id, _1.category_name ] })
    assert @response.data.all? { _1.confidence > 0.5 }
    assert_equal 4, request_bodies(%r{opencode\.ai}).size
    assert_equal [ "ruby_decision_model/0.3.0" ], WebMock::RequestRegistry.instance.requested_signatures.hash.keys.map { _1.headers["User-Agent"] }.uniq
  end

  test "a wrong key is a provider error, after one attempt (live)" do
    provider = Provider::JevGem.new("not-a-key", endpoint: ENDPOINT, model: MODEL)
    with_spike_cassette("jev/gem_bad_key") do
      @response = provider.decide(state: "NETFLIX.COM AUTOPAY 15.49", questions: { q: { type: "noul", instructions: "Is this a subscription?" } })
    end

    assert_not @response.success?
    assert_kind_of Provider::Jev::Error, @response.error
    assert_match(/\Aunauthorized/, @response.error.message)
    assert_equal 1, request_bodies(%r{opencode\.ai}).size, "a 401 isn't retried"
  end
end
