# frozen_string_literal: true

require_relative "test_helper"
require "dotenv"

require_relative "../lib/portfolio_performance_api/portfolio_store"
require_relative "../lib/portfolio_performance_api/transaction_sync"
require_relative "../lib/portfolio_performance_api/drive_client"
require_relative "../lib/portfolio_performance_api/sheets_client"

class SyncSheetsTest < Minitest::Test
  EXPECTED_ROWS = {
    "Deposit Account" => 91,
    "Call Money Account" => 1,
    "Foreign Currency Accounts USD" => 2,
    "Foreign Currency Accounts GBP" => 1,
    "Brokerage Account" => 9,
    "Cryptocurrency" => 7
  }.freeze
  ENV_KEYS = %w[
    GOOGLE_SERVICE_ACCOUNT_JSON
    GOOGLE_APPLICATION_CREDENTIALS
    SYNC_GOOGLE_DRIVE_FILE_ID_TEST
  ].freeze

  def setup
    @saved_env = ENV_KEYS.to_h { |key| [key, ENV[key]] }
    apply_dotenv_keys
    unless live_sheets?
      skip "set SYNC_GOOGLE_DRIVE_FILE_ID_TEST and Google credentials in .env to run live sync tests"
    end

    @loaded = PortfolioPerformanceApi::PortfolioStore.load(
      DEMO_PORTFOLIO_PATH,
      password: DEMO_PORTFOLIO_PASSWORD
    )
    @client = @loaded.client
    @names = PortfolioPerformanceApi::TransactionSync.uuid_names(@client)
    @vehicles = PortfolioPerformanceApi::TransactionSync.vehicles(@client)
    @titles = PortfolioPerformanceApi::SheetsClient.unique_titles(@vehicles)
    session = PortfolioPerformanceApi::DriveClient.new(
      credentials_json: PortfolioPerformanceApi::Config.service_account_json,
      file_id: PortfolioPerformanceApi::Config.sync_test_drive_file_id,
      scope: PortfolioPerformanceApi::DriveClient::SYNC_SCOPE
    )
    @sheets = PortfolioPerformanceApi::SheetsClient.new(
      session: session,
      spreadsheet_id: PortfolioPerformanceApi::Config.sync_test_drive_file_id
    )
    seed_spreadsheet_once
  end

  def teardown
    restore_env
  end

  def test_writes_all_demo_accounts_and_leaves_them_on_the_spreadsheet
    assert_equal @titles.sort, @sheets.sheet_titles.sort
    refute_includes @sheets.sheet_titles, "__pp_test__Call Money Account"

    @vehicles.zip(@titles).each do |vehicle, title|
      rows = @sheets.read_rows(title)
      parsed = PortfolioPerformanceApi::TransactionSync.parse_sheet(
        rows, vehicle.name, currency: vehicle.currency
      )
      plan = PortfolioPerformanceApi::TransactionSync.account_plan(
        @client, vehicle, rows, names: @names
      )
      expected = EXPECTED_ROWS.fetch(vehicle.name)

      assert_equal PortfolioPerformanceApi::TransactionSync::HEADERS, rows[0], title
      assert_equal expected, parsed.size, title
      assert_kind_of Numeric, rows[1][2], title
      assert_empty plan.create_sheet, title
      assert_empty plan.update_sheet, title
      assert_empty plan.create_portfolio, title
    end

    cash_title = PortfolioPerformanceApi::SheetsClient.sheet_title(:deposit, "Call Money Account")
    cash_rows = @sheets.read_rows(cash_title)
    assert_equal "2019-04-01", cash_rows[1][0].to_s
    assert_in_delta 500.0, cash_rows[1][2].to_f
    assert_equal "4a23e071-c072-482b-8dc4-68ca6d57ea89", cash_rows[1][6]
  end

  def test_sheet_row_missing_from_portfolio_is_planned_as_create
    rows = @sheets.read_rows(PortfolioPerformanceApi::SheetsClient.sheet_title(:deposit, "Call Money Account")) + [
      ["2026-08-15", "DEPOSIT", 10.0, "EUR", "Sheet only", "", ""]
    ]
    vehicle = @vehicles.find { |item| item.name == "Call Money Account" }
    plan = PortfolioPerformanceApi::TransactionSync.account_plan(
      @client, vehicle, rows, names: @names
    )

    assert_equal ["Sheet only"], plan.create_portfolio.map(&:description)
    assert_equal 1_000, plan.create_portfolio.first.signed_cents
    assert_empty plan.create_sheet
  end

  private

  def seed_spreadsheet_once
    return if self.class.instance_variable_get(:@seeded)

    @sheets.reset_sheets(@titles)
    chunk = PortfolioPerformanceApi::Config.sync_rows_chunk
    @vehicles.zip(@titles).each do |vehicle, title|
      plan = PortfolioPerformanceApi::TransactionSync.account_plan(
        @client, vehicle, [], names: @names
      )
      sheet_plan, = PortfolioPerformanceApi::TransactionSync.split_plan(plan)
      PortfolioPerformanceApi::TransactionSync.apply_sheet(
        @sheets, title, sheet_plan, skip_rows: 0, chunk_size: chunk, raw_rows: []
      )
    end
    self.class.instance_variable_set(:@seeded, true)
  end

  def live_sheets?
    !PortfolioPerformanceApi::Config.sync_test_drive_file_id.to_s.empty? &&
      !PortfolioPerformanceApi::Config.service_account_json.to_s.empty?
  end

  def apply_dotenv_keys
    path = File.expand_path("../.env", __dir__)
    return unless File.file?(path)

    Dotenv.parse(path).each do |key, value|
      ENV[key] = value if ENV_KEYS.include?(key) && !value.to_s.empty?
    end
  end

  def restore_env
    return unless @saved_env

    ENV_KEYS.each do |key|
      if @saved_env[key].nil?
        ENV.delete(key)
      else
        ENV[key] = @saved_env[key]
      end
    end
  end
end
