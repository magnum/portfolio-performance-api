# frozen_string_literal: true

require_relative "test_helper"
require "date"

require_relative "../lib/portfolio_performance_api/fineco_import"

class ImportLookupTest < Minitest::Test
  include PortfolioFixtures

  def test_account_exact_case_uuid_and_misses
    client = protobuf_client
    assert_equal "acc-cash", PortfolioPerformanceApi::FinecoImport.find_account(client, "Conto corrente").uuid
    assert_equal "acc-cash", PortfolioPerformanceApi::FinecoImport.find_account(client, "conto corrente").uuid
    assert_equal "acc-savings", PortfolioPerformanceApi::FinecoImport.find_account(client, "acc-savings").uuid
    assert_nil PortfolioPerformanceApi::FinecoImport.find_account(client, "missing")
    assert_nil PortfolioPerformanceApi::FinecoImport.find_account(client, "  ")
    assert_nil PortfolioPerformanceApi::FinecoImport.find_account(client, "Deposito titoli")
  end

  def test_security_and_vehicle
    client = protobuf_client
    assert_equal "sec-etf", PortfolioPerformanceApi::FinecoImport.find_security(client, "VWCE").uuid
    assert_equal "sec-etf", PortfolioPerformanceApi::FinecoImport.find_security(client, "vwce").uuid
    assert_equal "sec-etf", PortfolioPerformanceApi::FinecoImport.find_security(client, "sec-etf").uuid
    assert_nil PortfolioPerformanceApi::FinecoImport.find_security(client, "AMAZON.COM")

    vehicle = PortfolioPerformanceApi::FinecoImport.find_vehicle(client, "Deposito titoli")
    assert_equal :securities, vehicle.kind
    assert_equal "port-titoli", vehicle.uuid
    assert_equal "acc-cash", PortfolioPerformanceApi::FinecoImport.find_vehicle(client, "Conto corrente").uuid
    assert_nil PortfolioPerformanceApi::FinecoImport.find_vehicle(client, "Deposito titoli", kind: :deposit)
    assert_equal "port-titoli", PortfolioPerformanceApi::FinecoImport.find_vehicle(client, "Deposito titoli", kind: :securities).uuid
  end

  def test_last_date_ignores_other_accounts_and_undated
    client = protobuf_client
    client.transactions << PortfolioPerformanceApi::Proto::PTransaction.new(
      uuid: "tx-dated",
      type: :DEPOSIT,
      account: "acc-cash",
      date: Google::Protobuf::Timestamp.new(seconds: Time.utc(2024, 3, 10).to_i),
      currencyCode: "EUR",
      amount: 500
    )
    client.transactions << PortfolioPerformanceApi::Proto::PTransaction.new(
      uuid: "tx-later-other",
      type: :DEPOSIT,
      account: "acc-savings",
      date: Google::Protobuf::Timestamp.new(seconds: Time.utc(2025, 1, 1).to_i),
      currencyCode: "EUR",
      amount: 1
    )

    assert_equal Date.new(2024, 3, 10), PortfolioPerformanceApi::FinecoImport.last_transaction_date(client, "acc-cash")
    assert_nil PortfolioPerformanceApi::FinecoImport.last_transaction_date(client, "missing")
  end
end
