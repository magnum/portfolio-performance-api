# frozen_string_literal: true

require_relative "test_helper"
require "date"

require_relative "../lib/portfolio_performance_api/fineco_xls"
require_relative "../lib/portfolio_performance_api/fineco_import"

class ImportExistingTest < Minitest::Test
  include PortfolioFixtures

  def test_exact_identity_is_consumed_one_to_one
    client = protobuf_client
    account = account_named(client, "Conto corrente")
    visa = row(Date.new(2026, 8, 15), "VISA DEBIT", 9_900, :REMOVAL)
    PortfolioPerformanceApi::FinecoImport.append!(client, account, [visa])

    existing, missing = PortfolioPerformanceApi::FinecoImport.partition_existing(
      [visa, visa.dup, row(Date.new(2026, 8, 16), "Stipendio", 100_000, :DEPOSIT)],
      client,
      account
    )

    assert_equal ["VISA DEBIT"], existing.map(&:description)
    assert_equal ["VISA DEBIT", "Stipendio"], missing.map(&:description)
  end

  def test_share_match_within_seven_days_not_eight
    client = protobuf_client
    account = account_named(client, "Conto corrente")
    client.transactions << PortfolioPerformanceApi::Proto::PTransaction.new(
      uuid: "tx-pp-buy",
      type: :PURCHASE,
      account: "acc-cash",
      portfolio: "port-titoli",
      security: "sec-etf",
      currencyCode: "EUR",
      amount: 9_900,
      shares: 1_000_000_000,
      note: "Fineco PDF",
      date: Google::Protobuf::Timestamp.new(seconds: Time.utc(2026, 8, 14).to_i)
    )
    near = row(
      Date.new(2026, 8, 21),
      "Compravendita Titoli VWCE Qta/Val.nom. 10,000000",
      9_900,
      :REMOVAL,
      security: "VWCE",
      offset_account: "Deposito titoli"
    )
    far = near.dup
    far.date = Date.new(2026, 8, 22)

    existing, missing = PortfolioPerformanceApi::FinecoImport.partition_existing([near], client, account)
    assert_equal [near], existing
    assert_empty missing

    existing, missing = PortfolioPerformanceApi::FinecoImport.partition_existing([far], client, account)
    assert_empty existing
    assert_equal [far], missing
  end

  def test_cash_match_within_one_day_not_two
    client = protobuf_client
    account = account_named(client, "Conto corrente")
    client.transactions << PortfolioPerformanceApi::Proto::PTransaction.new(
      uuid: "tx-pp-cash",
      type: :REMOVAL,
      account: "acc-cash",
      currencyCode: "EUR",
      amount: 9_900,
      note: "other note",
      date: Google::Protobuf::Timestamp.new(seconds: Time.utc(2026, 8, 14).to_i)
    )
    near = row(Date.new(2026, 8, 15), "VISA", 9_900, :REMOVAL)
    far = row(Date.new(2026, 8, 16), "VISA", 9_900, :REMOVAL)

    existing, = PortfolioPerformanceApi::FinecoImport.partition_existing([near], client, account)
    assert_equal [near], existing

    existing, missing = PortfolioPerformanceApi::FinecoImport.partition_existing([far], client, account)
    assert_empty existing
    assert_equal [far], missing
  end

  def test_fx_inbound_matches_viewing_account_currency_amount
    client = protobuf_client
    client.accounts << PortfolioPerformanceApi::Proto::PAccount.new(
      uuid: "acc-usd", name: "USD010069756", currencyCode: "USD"
    )
    client.transactions << PortfolioPerformanceApi::Proto::PTransaction.new(
      uuid: "tx-fx-in",
      type: :CASH_TRANSFER,
      account: "acc-cash",
      otherAccount: "acc-usd",
      currencyCode: "EUR",
      amount: 4_000,
      note: "Fineco export",
      date: Google::Protobuf::Timestamp.new(seconds: Time.utc(2025, 10, 29).to_i),
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
    account = account_named(client, "USD010069756")
    inbound = row(
      Date.new(2025, 10, 29),
      "Cambio valuta Compravendita Divise",
      4_648,
      :DEPOSIT,
      offset_account: "EUR010069756"
    )

    existing, missing = PortfolioPerformanceApi::FinecoImport.partition_existing([inbound], client, account)
    assert_equal [inbound], existing
    assert_empty missing
  end

  def test_deposit_identity_omits_security_buy_includes_it
    account = PortfolioPerformanceApi::Proto::PAccount.new(uuid: "a", name: "EUR", currencyCode: "EUR")
    deposit = row(Date.new(2025, 10, 28), "Titoli AMAZON", 100, :DEPOSIT, security: "AMAZON.COM")
    buy = row(
      Date.new(2025, 10, 28),
      "Titoli VWCE Qta/Val.nom. 1",
      100,
      :REMOVAL,
      security: "VWCE",
      offset_account: "titoli"
    )

    assert_equal(
      PortfolioPerformanceApi::TransactionIdentity.id("EUR", Date.new(2025, 10, 28), 100, "Titoli AMAZON", "", ""),
      PortfolioPerformanceApi::FinecoImport.identity_for(deposit, account)
    )
    assert_equal(
      PortfolioPerformanceApi::TransactionIdentity.id(
        "EUR", Date.new(2025, 10, 28), -100, "Titoli VWCE Qta/Val.nom. 1", "titoli", "VWCE"
      ),
      PortfolioPerformanceApi::FinecoImport.identity_for(buy, account)
    )
  end

  private

  def account_named(client, name)
    client.accounts.find { |account| account.name == name }
  end

  def row(date, description, cents, type, security: nil, offset_account: nil)
    PortfolioPerformanceApi::FinecoXls::Row.new(
      date: date,
      description: description,
      amount_cents: cents,
      type: type,
      security: security,
      offset_account: offset_account
    )
  end
end
