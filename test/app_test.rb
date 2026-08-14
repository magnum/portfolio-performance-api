# frozen_string_literal: true

require_relative "test_helper"

class AppTest < Minitest::Test
  include Rack::Test::Methods
  include PortfolioFixtures

  def app
    PortfolioPerformanceApi::App.freeze.app
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
end
