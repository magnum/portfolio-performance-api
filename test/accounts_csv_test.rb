# frozen_string_literal: true

require_relative "test_helper"
require "csv"

class AccountsCsvTest < Minitest::Test
  def test_header_and_rows_use_semicolon
    csv = PortfolioPerformanceApi::AccountsCsv.generate(
      accounts: [
        {
          uuid: "acc-cash",
          name: "Conto corrente",
          currency: "EUR",
          retired: false,
          balance: 875.0,
          balance_cents: 87_500
        },
        {
          uuid: "acc-old",
          name: "Chiuso",
          currency: "EUR",
          retired: true,
          balance: 0.01,
          balance_cents: 1
        }
      ]
    )

    lines = csv.split("\r\n")
    assert_equal "uuid;name;currency;retired;balance;balance_cents", lines.first
    assert_equal "acc-cash;Conto corrente;EUR;FALSE;875,00;87500", lines[1]
    assert_equal "acc-old;Chiuso;EUR;TRUE;0,01;1", lines[2]
  end

  def test_quotes_fields_with_separator_or_quotes
    csv = PortfolioPerformanceApi::AccountsCsv.generate(
      accounts: [
        {
          uuid: "acc-1",
          name: 'Conto "speciale";risparmio',
          currency: "EUR",
          retired: false,
          balance: 10,
          balance_cents: 1_000
        }
      ]
    )

    row = CSV.parse(csv, col_sep: ";", row_sep: "\r\n", headers: true).first
    assert_equal 'Conto "speciale";risparmio', row["name"]
    assert_equal "10,00", row["balance"]
  end
end
