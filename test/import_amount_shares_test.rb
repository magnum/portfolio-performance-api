# frozen_string_literal: true

require_relative "test_helper"
require "date"

require_relative "../lib/portfolio_performance_api/fineco_xls"
require_relative "../lib/portfolio_performance_api/fineco_import"

class ImportAmountSharesTest < Minitest::Test
  def test_italian_and_us_decimals
    number = PortfolioPerformanceApi::FinecoImport.method(:italian_number)
    assert_equal "1234.56", number.call("1.234,56")
    assert_equal "12.00", number.call("12,00")
    assert_equal "12.00", number.call("12.00")
    assert_equal "100", number.call("€ 100")
  end

  def test_shares_from_description_or_raw_cells
    row = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2025, 10, 28),
      description: "Compravendita Titoli AMAZON.COM Qta/Val.nom. 20,000000",
      amount_cents: 1,
      type: :REMOVAL
    )
    assert_equal 2_000_000_000, PortfolioPerformanceApi::FinecoImport.extract_shares(row)

    hidden = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2025, 10, 28),
      description: "Compravendita Titoli VWCE",
      amount_cents: 1,
      type: :REMOVAL,
      raw: ["Qta/Val.nom. 10,5"]
    )
    assert_equal 1_050_000_000, PortfolioPerformanceApi::FinecoImport.extract_shares(hidden)
  end

  def test_shares_missing_or_invalid_are_zero
    missing = PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2025, 10, 28),
      description: "Stipendio",
      amount_cents: 1,
      type: :DEPOSIT
    )
    invalid = missing.dup
    invalid.description = "Qta/Val.nom. xx"
    assert_equal 0, PortfolioPerformanceApi::FinecoImport.extract_shares(missing)
    assert_equal 0, PortfolioPerformanceApi::FinecoImport.extract_shares(invalid)
  end
end
