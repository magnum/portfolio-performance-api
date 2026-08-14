# frozen_string_literal: true

require_relative "test_helper"

class ParserBalancesTest < Minitest::Test
  include PortfolioFixtures

  def test_xml_account_balances
    result = PortfolioPerformanceApi::FileReader.read(XML)
    client = PortfolioPerformanceApi::Parser.parse(result)
    payload = PortfolioPerformanceApi::Balances.compute(client)

    by_name = payload[:accounts].to_h { |row| [row[:name], row] }
    assert_in_delta 875.0, by_name["Conto corrente"][:balance]
    assert_in_delta 115.0, by_name["Risparmio"][:balance]
    assert_in_delta 0.01, by_name["Chiuso"][:balance]
    assert_equal 87500, by_name["Conto corrente"][:balance_cents]
    assert_equal "deposit", by_name["Conto corrente"][:kind]
    assert_equal "securities", by_name["Deposito titoli"][:kind]
    assert_in_delta 100.0, by_name["Deposito titoli"][:balance]
    assert_equal "acc-cash", by_name["Deposito titoli"][:reference_account_uuid]
  end

  def test_protobuf_cash_transfer_both_sides
    result = PortfolioPerformanceApi::FileReader.read(encrypted_protobuf, password: "secret")
    client = PortfolioPerformanceApi::Parser.parse(result)
    payload = PortfolioPerformanceApi::Balances.compute(client)

    by_name = payload[:accounts].to_h { |row| [row[:name], row] }
    assert_in_delta 875.0, by_name["Conto corrente"][:balance]
    assert_in_delta 115.0, by_name["Risparmio"][:balance]
    assert_equal "securities", by_name["Deposito titoli"][:kind]
    assert_in_delta 100.0, by_name["Deposito titoli"][:balance]
  end

  def test_exclude_retired
    result = PortfolioPerformanceApi::FileReader.read(XML)
    client = PortfolioPerformanceApi::Parser.parse(result)
    payload = PortfolioPerformanceApi::Balances.compute(client, include_retired: false)
    names = payload[:accounts].map { |row| row[:name] }
    refute_includes names, "Chiuso"
  end
end
