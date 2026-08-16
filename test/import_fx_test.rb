# frozen_string_literal: true

require_relative "test_helper"
require "date"

require_relative "../lib/portfolio_performance_api/fineco_import"

class ImportFxTest < Minitest::Test
  include PortfolioFixtures

  def test_encode_decimal_matches_portfolio_performance_wire_format
    rate = PortfolioPerformanceApi::FinecoImport.encode_decimal(4_000.to_f / 4_648)
    assert_equal 10, rate.scale
    assert_equal 10, rate.precision
    assert_equal ["0200f2e14b"].pack("H*"), rate.value

    over_one = PortfolioPerformanceApi::FinecoImport.encode_decimal(550_000.to_f / 475_696)
    assert_equal 10, over_one.scale
    assert_equal 11, over_one.precision
    assert_equal ["02b12635e3"].pack("H*"), over_one.value
  end

  def test_encode_decimal_rejects_non_positive_rate
    error = assert_raises(ArgumentError) { PortfolioPerformanceApi::FinecoImport.encode_decimal(0) }
    assert_includes error.message, "positive"
    assert_raises(ArgumentError) { PortfolioPerformanceApi::FinecoImport.encode_decimal(-1) }
  end

  def test_same_currency_convert_is_identity
    client = protobuf_client
    cash = client.accounts.first
    savings = client.accounts[1]
    assert_equal 12_345, PortfolioPerformanceApi::FinecoImport.convert_cents(client, cash, savings, 12_345, Date.new(2026, 1, 1))
  end

  def test_uses_closest_dated_rate_and_inverse_pair
    client = protobuf_client
    client.accounts << PortfolioPerformanceApi::Proto::PAccount.new(
      uuid: "acc-usd", name: "USD010069756", currencyCode: "USD"
    )
    client.transactions << fx_transfer("old", Date.new(2024, 1, 1), 1_000, 2_000)
    client.transactions << fx_transfer("near", Date.new(2025, 10, 29), 4_000, 4_648)
    eur = client.accounts.find { |account| account.uuid == "acc-cash" }
    usd = client.accounts.find { |account| account.uuid == "acc-usd" }
    usd_from_eur = PortfolioPerformanceApi::FinecoImport.convert_cents(client, eur, usd, 4_000, Date.new(2025, 10, 30))
    assert_equal 4_648, usd_from_eur

    eur_from_usd = PortfolioPerformanceApi::FinecoImport.convert_cents(client, usd, eur, 4_648, Date.new(2025, 10, 30))
    assert_equal 4_000, eur_from_usd
  end

  def test_missing_rate_and_unrelated_unit_currency
    client = protobuf_client
    client.accounts << PortfolioPerformanceApi::Proto::PAccount.new(
      uuid: "acc-usd", name: "USD010069756", currencyCode: "USD"
    )
    eur = client.accounts.find { |account| account.uuid == "acc-cash" }
    usd = client.accounts.find { |account| account.uuid == "acc-usd" }
    error = assert_raises(ArgumentError) do
      PortfolioPerformanceApi::FinecoImport.convert_cents(client, eur, usd, 100, Date.new(2026, 1, 1))
    end
    assert_includes error.message, "no FX rate"

    unit = PortfolioPerformanceApi::Proto::PTransactionUnit.new(
      type: :GROSS_VALUE, amount: 1, currencyCode: "GBP", fxAmount: 2, fxCurrencyCode: "JPY"
    )
    error = assert_raises(ArgumentError) do
      PortfolioPerformanceApi::FinecoImport.rate_from_unit(unit, "EUR", "USD")
    end
    assert_includes error.message, "does not match"
  end

  def test_amount_in_account_cents_reads_fx_amount
    account = PortfolioPerformanceApi::Proto::PAccount.new(uuid: "acc-usd", name: "USD", currencyCode: "USD")
    tx = PortfolioPerformanceApi::Proto::PTransaction.new(
      type: :CASH_TRANSFER,
      currencyCode: "EUR",
      amount: 4_000,
      units: [
        PortfolioPerformanceApi::Proto::PTransactionUnit.new(
          type: :GROSS_VALUE,
          amount: 4_000,
          currencyCode: "EUR",
          fxAmount: 4_648,
          fxCurrencyCode: "USD"
        )
      ]
    )

    assert_equal 4_648, PortfolioPerformanceApi::FinecoImport.amount_in_account_cents(tx, account)
    eur = PortfolioPerformanceApi::Proto::PAccount.new(uuid: "acc-cash", name: "EUR", currencyCode: "EUR")
    assert_equal 4_000, PortfolioPerformanceApi::FinecoImport.amount_in_account_cents(tx, eur)
  end

  private

  def fx_transfer(uuid, date, eur_cents, usd_cents)
    PortfolioPerformanceApi::Proto::PTransaction.new(
      uuid: uuid,
      type: :CASH_TRANSFER,
      account: "acc-cash",
      otherAccount: "acc-usd",
      currencyCode: "EUR",
      amount: eur_cents,
      date: Google::Protobuf::Timestamp.new(seconds: Time.utc(date.year, date.month, date.day).to_i),
      units: [
        PortfolioPerformanceApi::Proto::PTransactionUnit.new(
          type: :GROSS_VALUE,
          amount: eur_cents,
          currencyCode: "EUR",
          fxAmount: usd_cents,
          fxCurrencyCode: "USD"
        )
      ]
    )
  end
end
