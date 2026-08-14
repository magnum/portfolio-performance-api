# frozen_string_literal: true

require_relative "test_helper"
require "csv"

class AccountsCsvTest < Minitest::Test
  def test_header_and_rows_use_semicolon
    csv = PortfolioPerformanceApi::AccountsCsv.generate(
      {
        accounts: [
          {
            uuid: "acc-cash",
            kind: "deposit",
            name: "Conto corrente",
            currency: "EUR",
            retired: false,
            balance: 875.0,
            balance_cents: 87_500
          },
          {
            uuid: "port-titoli",
            kind: "securities",
            name: "Deposito titoli",
            currency: "EUR",
            retired: false,
            balance: 100.0,
            balance_cents: 10_000,
            reference_account_uuid: "acc-cash"
          }
        ]
      }
    )

    lines = csv.split("\r\n")
    assert_equal "uuid;kind;name;currency;retired;balance;balance_cents;reference_account_uuid", lines.first
    assert_equal "acc-cash;deposit;Conto corrente;EUR;FALSE;875.00;87500;", lines[1]
    assert_equal "port-titoli;securities;Deposito titoli;EUR;FALSE;100.00;10000;acc-cash", lines[2]
  end

  def test_italian_locale_uses_comma_decimals
    csv = PortfolioPerformanceApi::AccountsCsv.generate(
      { accounts: [{ uuid: "acc-cash", kind: "deposit", name: "Conto corrente", currency: "EUR", retired: false, balance: 875.0, balance_cents: 87_500 }] },
      locale: "it"
    )

    assert_includes csv.split("\r\n")[1], "875,00"
  end

  def test_quotes_fields_with_separator_or_quotes
    csv = PortfolioPerformanceApi::AccountsCsv.generate(
      {
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
      }
    )

    row = CSV.parse(csv, col_sep: ";", row_sep: "\r\n", headers: true).first
    assert_equal 'Conto "speciale";risparmio', row["name"]
    assert_equal "10.00", row["balance"]
  end
end
