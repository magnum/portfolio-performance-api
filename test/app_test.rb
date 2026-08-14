# frozen_string_literal: true

require_relative "test_helper"

class AppTest < Minitest::Test
  include Rack::Test::Methods
  include PortfolioFixtures

  def app
    PortfolioPerformanceApi::App
  end

  def setup
    source = Object.new
    bytes = encrypted_xml
    source.define_singleton_method(:fetch) do
      { bytes: bytes, meta: { source: "test", name: "demo.portfolio" } }
    end
    cache = PortfolioPerformanceApi::Cache.new(ttl: 60)
    PortfolioPerformanceApi::App.snapshot = PortfolioPerformanceApi::Snapshot.new(source: source, cache: cache)
  end

  def teardown
    PortfolioPerformanceApi::App.snapshot = nil
  end

  def test_health_is_public
    get "/health"
    assert last_response.ok?
    body = JSON.parse(last_response.body)
    assert_equal "ok", body["status"]
  end

  def test_accounts_requires_api_key
    get "/accounts"
    assert_equal 401, last_response.status
  end

  def test_accounts_with_header
    get "/accounts", {}, { "HTTP_X_API_KEY" => "test-key" }
    assert last_response.ok?, last_response.body
    body = JSON.parse(last_response.body)
    names = body.fetch("accounts").map { |row| row["name"] }
    assert_includes names, "Conto corrente"
    assert_equal "deposit", body["accounts"].find { |row| row["name"] == "Conto corrente" }["kind"]
    titoli = body["accounts"].find { |row| row["name"] == "Deposito titoli" }
    assert_equal "securities", titoli["kind"]
    assert_in_delta 100.0, titoli["balance"]
    assert_in_delta 875.0, body["accounts"].find { |row| row["name"] == "Conto corrente" }["balance"]
    refute body["cached"]
  end

  def test_cache_hit_then_nocache
    header = { "HTTP_X_API_KEY" => "test-key" }
    get "/accounts", {}, header
    refute JSON.parse(last_response.body)["cached"]

    get "/accounts", {}, header
    assert JSON.parse(last_response.body)["cached"]

    get "/accounts?nocache", {}, header
    refute JSON.parse(last_response.body)["cached"]
  end

  def test_root_alias
    get "/", {}, { "HTTP_X_API_KEY" => "test-key" }
    assert last_response.ok?, last_response.body
    body = JSON.parse(last_response.body)
    assert body.key?("accounts")
  end

  def test_bearer_token
    get "/accounts", {}, { "HTTP_AUTHORIZATION" => "Bearer test-key" }
    assert last_response.ok?, last_response.body
  end

  def test_accounts_with_query_apikey
    get "/accounts", { apikey: "test-key" }
    assert last_response.ok?, last_response.body
    body = JSON.parse(last_response.body)
    assert body.key?("accounts")
  end

  def test_accounts_csv_with_query_apikey
    get "/accounts.csv", { apikey: "test-key" }
    assert last_response.ok?, last_response.body
    assert_includes last_response.content_type, "text/csv"
    assert_includes last_response.body, "Conto corrente"
  end

  def test_invalid_query_apikey
    get "/accounts", { apikey: "wrong" }
    assert_equal 401, last_response.status
  end

  def test_header_wins_over_query_apikey
    get "/accounts", { apikey: "wrong" }, { "HTTP_X_API_KEY" => "test-key" }
    assert last_response.ok?, last_response.body
  end

  def test_accounts_json_extension
    get "/accounts.json", {}, { "HTTP_X_API_KEY" => "test-key" }
    assert last_response.ok?, last_response.body
    assert_includes last_response.content_type, "application/json"
    body = JSON.parse(last_response.body)
    assert body.key?("accounts")
  end

  def test_accounts_csv_requires_api_key
    get "/accounts.csv"
    assert_equal 401, last_response.status
  end

  def test_accounts_csv
    get "/accounts.csv", {}, { "HTTP_X_API_KEY" => "test-key" }
    assert last_response.ok?, last_response.body
    assert_includes last_response.content_type, "text/csv"
    assert_match(/filename="accounts-en.csv"/, last_response["Content-Disposition"])

    lines = last_response.body.split("\r\n")
    assert_equal "uuid;kind;name;currency;retired;balance;balance_cents;reference_account_uuid", lines.first
    cash = lines.find { |line| line.include?("Conto corrente") }
    assert_equal "acc-cash;deposit;Conto corrente;EUR;FALSE;875.00;87500;", cash
    titoli = lines.find { |line| line.include?("Deposito titoli") }
    assert_equal "port-titoli;securities;Deposito titoli;EUR;FALSE;100.00;10000;acc-cash", titoli
  end

  def test_accounts_csv_italian_locale
    get "/accounts.csv", { locale: "it" }, { "HTTP_X_API_KEY" => "test-key" }
    assert last_response.ok?, last_response.body
    assert_equal "it", last_response["Content-Language"]
    cash = last_response.body.split("\r\n").find { |line| line.include?("Conto corrente") }
    assert_equal "acc-cash;deposit;Conto corrente;EUR;FALSE;875,00;87500;", cash
  end
end
