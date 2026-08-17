# frozen_string_literal: true

require_relative "test_helper"
require "date"

require_relative "../lib/portfolio_performance_api/portfolio_store"
require_relative "../lib/portfolio_performance_api/transaction_sync"
require_relative "../lib/portfolio_performance_api/sheets_client"

class SyncDemoTest < Minitest::Test
  VEHICLE_NAMES = [
    "Deposit Account",
    "Call Money Account",
    "Foreign Currency Accounts USD",
    "Foreign Currency Accounts GBP",
    "Brokerage Account",
    "Cryptocurrency"
  ].freeze

  def setup
    @loaded = PortfolioPerformanceApi::PortfolioStore.load(
      DEMO_PORTFOLIO_PATH,
      password: DEMO_PORTFOLIO_PASSWORD
    )
    @client = @loaded.client
    @names = PortfolioPerformanceApi::TransactionSync.uuid_names(@client)
    @vehicles = PortfolioPerformanceApi::TransactionSync.vehicles(@client)
  end

  def test_demo_portfolio_loads_known_accounts
    assert File.file?(DEMO_PORTFOLIO_PATH)
    assert @loaded.encrypted
    assert_equal "EUR", @client.baseCurrency
    assert_equal VEHICLE_NAMES, @vehicles.map(&:name)
    assert_equal 102, @client.transactions.size
  end

  def test_empty_sheet_plans_create_all_demo_transactions
    expected = {
      "Deposit Account" => 91,
      "Call Money Account" => 1,
      "Foreign Currency Accounts USD" => 2,
      "Foreign Currency Accounts GBP" => 1,
      "Brokerage Account" => 9,
      "Cryptocurrency" => 7
    }
    expected.each do |name, count|
      vehicle = vehicle_named(name)
      plan = PortfolioPerformanceApi::TransactionSync.account_plan(
        @client, vehicle, [], names: @names
      )
      assert_equal count, plan.create_sheet.size, name
      assert_empty plan.update_sheet, name
      assert_empty plan.create_portfolio, name
      assert_empty plan.update_portfolio, name
    end
  end

  def test_purchase_from_deposit_sets_brokerage_destination
    vehicle = vehicle_named("Deposit Account")
    records = @client.transactions.filter_map do |tx|
      PortfolioPerformanceApi::TransactionSync.from_proto(tx, vehicle, names: @names)
    end
    purchase = records.find { |record| record.type == "PURCHASE" }

    assert_equal "Brokerage Account", purchase.destination
    assert purchase.signed_cents.negative?
    row = PortfolioPerformanceApi::TransactionSync.to_sheet_row(purchase)
    assert_kind_of Numeric, row[2]
    assert_equal "Brokerage Account", row[5]
  end

  def test_round_trip_sheet_then_plan_is_noop
    vehicle = vehicle_named("Call Money Account")
    sheets = MemorySheets.new
    title = "Call Money Account"
    plan = PortfolioPerformanceApi::TransactionSync.account_plan(@client, vehicle, [], names: @names)
    sheet_plan, = PortfolioPerformanceApi::TransactionSync.split_plan(plan)

    created, updated = PortfolioPerformanceApi::TransactionSync.apply_sheet(
      sheets, title, sheet_plan, skip_rows: 0, chunk_size: 100, raw_rows: [], kind: vehicle.kind
    )
    second = PortfolioPerformanceApi::TransactionSync.account_plan(
      @client, vehicle, sheets.read_rows(title), names: @names
    )

    assert_equal 1, created
    assert_equal 0, updated
    assert_equal 1, sheets.write_count
    assert_kind_of Numeric, sheets.read_rows(title)[1][2]
    assert_in_delta 500.0, sheets.read_rows(title)[1][2]
    assert_empty second.create_sheet
    assert_empty second.update_sheet
    assert_empty second.create_portfolio
    assert_empty second.update_portfolio
  end

  def test_sheet_only_row_creates_portfolio_transaction
    vehicle = vehicle_named("Call Money Account")
    plan = PortfolioPerformanceApi::TransactionSync.account_plan(@client, vehicle, [], names: @names)
    grid = PortfolioPerformanceApi::TransactionSync.materialize_sheet([], plan, skip_rows: 0, kind: vehicle.kind)
    grid << ["2026-08-15", "REMOVAL", -12.5, "EUR", "Test fee", "", ""]
    second = PortfolioPerformanceApi::TransactionSync.account_plan(
      @client, vehicle, grid, names: @names
    )

    assert_equal ["Test fee"], second.create_portfolio.map(&:description)
    assert_equal(-1_250, second.create_portfolio.first.signed_cents)

    before = @client.transactions.size
    applied = PortfolioPerformanceApi::TransactionSync.apply_portfolio!(
      @client, vehicle, second.create_portfolio
    )
    imported = @client.transactions.last

    assert_equal 1, applied
    assert_equal before + 1, @client.transactions.size
    assert_equal :REMOVAL, imported.type
    assert_equal 1_250, imported.amount
    assert_equal "Test fee", imported.note
    assert_equal vehicle.uuid, imported.account
  end

  def test_skip_rows_are_left_untouched
    vehicle = vehicle_named("Call Money Account")
    raw = [["keep me"], %w[date type amount currency description destination uuid]]
    plan = PortfolioPerformanceApi::TransactionSync.account_plan(
      @client, vehicle, raw, names: @names, skip_rows: 1
    )
    grid = PortfolioPerformanceApi::TransactionSync.materialize_sheet(raw, plan, skip_rows: 1, kind: vehicle.kind)

    assert_equal ["keep me"], grid[0]
    assert_equal PortfolioPerformanceApi::TransactionSync.headers_for(vehicle.kind), grid[1]
    assert_equal "2019-04-01", grid[2][0]
    assert_in_delta 500.0, grid[2][2]
  end

  def test_chunked_write_count_follows_chunk_size
    vehicle = vehicle_named("Cryptocurrency")
    sheets = MemorySheets.new
    plan = PortfolioPerformanceApi::TransactionSync.account_plan(@client, vehicle, [], names: @names)
    sheet_plan, = PortfolioPerformanceApi::TransactionSync.split_plan(plan)

    PortfolioPerformanceApi::TransactionSync.apply_sheet(
      sheets, "Cryptocurrency", sheet_plan, skip_rows: 0, chunk_size: 3, raw_rows: [], kind: vehicle.kind
    )

    # header + 7 txs = 8 rows, chunk 3 → 3 writes
    assert_equal 3, sheets.write_count
    assert_equal 8, sheets.read_rows("Cryptocurrency").size
  end

  def test_unique_sheet_titles_prefix_kind_and_disambiguate_same_kind
    cash = vehicle_named("Deposit Account")
    brokerage = vehicle_named("Brokerage Account")
    titles = PortfolioPerformanceApi::SheetsClient.unique_titles([cash, brokerage, cash])
    assert_equal ["deposit - Deposit Account", "securities - Brokerage Account", "deposit - Deposit Account (2)"], titles
  end

  def test_dump_round_trip_keeps_password
    bytes = PortfolioPerformanceApi::PortfolioStore.dump(@loaded)
    reloaded = PortfolioPerformanceApi::PortfolioStore.load_bytes(
      bytes,
      password: DEMO_PORTFOLIO_PASSWORD,
      path: "roundtrip.portfolio"
    )
    assert_equal @client.accounts.size, reloaded.client.accounts.size
    assert_equal @client.transactions.size, reloaded.client.transactions.size
  end

  private

  def vehicle_named(name)
    found = @vehicles.find { |vehicle| vehicle.name == name }
    flunk "missing vehicle #{name}" unless found
    found
  end

  class MemorySheets
    attr_reader :write_count

    def initialize
      @grids = {}
      @write_count = 0
    end

    def read_rows(title)
      Array(@grids[title])
    end

    def write_chunks(title, grid, start_row:, chunk_size:)
      chunks = PortfolioPerformanceApi::TransactionSync.sheet_chunks(
        grid, start_row: start_row, chunk_size: chunk_size
      )
      @write_count += chunks.size
      @grids[title] = grid
    end
  end
end
