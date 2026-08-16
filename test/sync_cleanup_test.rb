# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

require_relative "../lib/portfolio_performance_api/sheets_client"
require_relative "../lib/portfolio_performance_api/sync"

class SyncCleanupTest < Minitest::Test
  def test_confirm_choice_parses_y_n_a
    assert_equal :yes, PortfolioPerformanceApi::Sync.confirm_choice("y")
    assert_equal :yes, PortfolioPerformanceApi::Sync.confirm_choice("Y\n")
    assert_equal :yes, PortfolioPerformanceApi::Sync.confirm_choice("yes")
    assert_equal :all, PortfolioPerformanceApi::Sync.confirm_choice("a")
    assert_equal :all, PortfolioPerformanceApi::Sync.confirm_choice("ALL")
    assert_equal :no, PortfolioPerformanceApi::Sync.confirm_choice("n")
    assert_equal :no, PortfolioPerformanceApi::Sync.confirm_choice("N")
    assert_equal :no, PortfolioPerformanceApi::Sync.confirm_choice("\e")
    assert_equal :no, PortfolioPerformanceApi::Sync.confirm_choice("")
    assert_equal :no, PortfolioPerformanceApi::Sync.confirm_choice(nil)
  end

  def test_clear_data_rows_keeps_skip_rows_and_header
    session = FakeSession.new
    sheets = PortfolioPerformanceApi::SheetsClient.new(session: session, spreadsheet_id: "ssid")

    sheets.clear_data_rows("EUR010069756", skip_rows: 1)

    assert_equal :post, session.calls.last[:method]
    assert_match(/ssid/, session.calls.last[:uri])
    assert_match(/A3%3AZ/, session.calls.last[:uri])
    assert_match(/:clear\z/, session.calls.last[:uri])
  end

  def test_clear_data_rows_starts_after_header_when_skip_is_zero
    session = FakeSession.new
    sheets = PortfolioPerformanceApi::SheetsClient.new(session: session, spreadsheet_id: "ssid")

    sheets.clear_data_rows("Call Money Account", skip_rows: 0)

    assert_match(/A2%3AZ/, session.calls.last[:uri])
  end

  def test_cleanup_clears_confirmed_sheet_and_skips_the_rest
    sheets = MemoryCleanupSheets.new
    sheets.write("Keep", [%w[date type], ["2022-01-01", "DEPOSIT"]])
    sheets.write("Wipe", [%w[date type], ["2022-01-02", "REMOVAL"], ["2022-01-03", "DEPOSIT"]])
    sheets.write("Empty", [%w[date type]])
    answers = [:no, :yes]
    sync = PortfolioPerformanceApi::Sync.new
    sync.define_singleton_method(:confirm_cleanup) do |_id, title, gid: nil|
      fail "empty sheet should not prompt" if title == "Empty"

      answers.shift
    end

    capture_io do
      sync.cleanup(
        sheets: sheets,
        spreadsheet_id: "ssid",
        skip_rows: 0,
        titles: %w[Keep Wipe Empty]
      )
    end

    assert_equal [%w[date type], ["2022-01-01", "DEPOSIT"]], sheets.read_rows("Keep")
    assert_equal [%w[date type]], sheets.read_rows("Wipe")
    assert_equal [%w[date type]], sheets.read_rows("Empty")
    assert_equal ["Wipe"], sheets.cleared
  end

  def test_cleanup_all_clears_current_and_following_sheets
    sheets = MemoryCleanupSheets.new
    sheets.write("Keep", [%w[date type], ["2022-01-01", "DEPOSIT"]])
    sheets.write("First", [%w[date type], ["2022-01-02", "REMOVAL"]])
    sheets.write("Second", [%w[date type], ["2022-01-03", "DEPOSIT"]])
    sheets.write("Empty", [%w[date type]])
    sheets.write("Third", [%w[date type], ["2022-01-04", "FEE"]])
    prompted = []
    sync = PortfolioPerformanceApi::Sync.new
    sync.define_singleton_method(:confirm_cleanup) do |_id, title, gid: nil|
      prompted << title
      prompted.size == 1 ? :no : :all
    end

    capture_io do
      sync.cleanup(
        sheets: sheets,
        spreadsheet_id: "ssid",
        skip_rows: 0,
        titles: %w[Keep First Second Empty Third]
      )
    end

    assert_equal %w[Keep First], prompted
    assert_equal [%w[date type], ["2022-01-01", "DEPOSIT"]], sheets.read_rows("Keep")
    assert_equal [%w[date type]], sheets.read_rows("First")
    assert_equal [%w[date type]], sheets.read_rows("Second")
    assert_equal [%w[date type]], sheets.read_rows("Empty")
    assert_equal [%w[date type]], sheets.read_rows("Third")
    assert_equal %w[First Second Third], sheets.cleared
  end

  def test_confirm_prompt_text_and_n
    stdin = StringIO.new("n\n")
    stderr = StringIO.new
    original_stdin = $stdin
    original_stderr = $stderr
    $stdin = stdin
    $stderr = stderr
    begin
      assert_equal :no, PortfolioPerformanceApi::Sync.new.send(:confirm_cleanup, "ssid", "EUR010069756")
    ensure
      $stdin = original_stdin
      $stderr = original_stderr
    end
    assert_includes visible_text(stderr.string),
                    "All rows > headers in ssid, sheet EUR010069756 will be deleted: are you sure? y/n/a "
    assert_includes stderr.string, "https://docs.google.com/spreadsheets/d/ssid/edit"
  end

  private

  def visible_text(text)
    text.to_s.gsub(/\e\]8;;.*?\e\\/, "")
  end

  class FakeSession
    attr_reader :calls

    def initialize
      @calls = []
    end

    def api_request(uri, method: :get, body: nil, content_type: nil)
      @calls << { uri: uri.to_s, method: method, body: body, content_type: content_type }
      Struct.new(:body).new("{}")
    end
  end

  class MemoryCleanupSheets
    attr_reader :cleared

    def initialize
      @grids = {}
      @cleared = []
    end

    def write(title, rows)
      @grids[title] = rows
    end

    def sheet_titles
      @grids.keys
    end

    def read_rows(title)
      Array(@grids[title])
    end

    def clear_data_rows(title, skip_rows: 0)
      keep = Integer(skip_rows) + 1
      @grids[title] = Array(@grids[title]).first(keep)
      @cleared << title
    end
  end
end
