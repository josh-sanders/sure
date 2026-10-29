# The two sample statements' answers, and how an extraction is scored
# against them. Shared by the statement tests.
module StatementScoring
  FILES = Rails.root.join("test/fixtures/files/statements")

  STATEMENTS = {
      "bac_ocr" => {
        opening: 40_000.0, closing: 44_079.83,
        transactions: [ [ "02-01", -24.5 ], [ "02-01", -20.0 ], [ "02-03", -30.0 ], [ "02-04", 2575.0 ], [ "02-11", 300.0 ],
                        [ "02-16", -50.0 ], [ "02-17", -40.0 ], [ "02-17", -78.34 ], [ "02-18", 2575.0 ], [ "02-18", -15.0 ],
                        [ "02-24", -150.0 ], [ "02-24", 25.0 ], [ "02-28", -987.33 ] ]
      },
      "impact_scanned" => {
        opening: 69.96, closing: 586.71,
        transactions: [ [ "10-02", -4.23 ], [ "10-03", 763.01 ], [ "10-04", -11.68 ], [ "10-05", -9.98 ], [ "10-05", -25.5 ],
                        [ "10-08", -59.08 ], [ "10-12", -69.0 ], [ "10-14", -180.63 ], [ "10-14", -18.96 ], [ "10-16", 763.01 ],
                        [ "10-22", -140.0 ], [ "10-28", -91.06 ], [ "10-30", -451.2 ], [ "10-30", -37.07 ], [ "10-30", -18.67 ],
                        [ "10-31", -100.0 ], [ "10-31", -78.24 ], [ "10-31", 350.0 ], [ "11-02", -52.23 ], [ "11-09", 0.26 ],
                        [ "11-09", -12.0 ] ],
        alternatives: { [ "10-08", -59.08 ] => [ "10-07", -31.57 ] }
      }
    }.freeze

  # Transactions matched on month-day and signed amount, each at most once.
  # reconciles: the opening balance plus every transaction makes the closing
  # one, a check Sure could run on any extraction without knowing the answer.
  def score(value, truth)
    got = Array(value[:transactions]).map { |t| [ t["date"].to_s[5, 5], t["amount"].to_f.round(2) ] }
    remaining = got.dup
    matched = truth[:transactions].count do |expected|
      index = remaining.index(expected) || remaining.index(truth.dig(:alternatives, expected))
      remaining.delete_at(index) if index
    end
    opening, closing = value.values_at(:opening_balance, :closing_balance)
    { matched:, of: truth[:transactions].size, extra: remaining.size, balances: [ opening, closing ] == truth.values_at(:opening, :closing),
      reconciles: !opening.nil? && !closing.nil? && (opening + got.sum(&:last)).round(2) == closing.round(2) }
  end
end
