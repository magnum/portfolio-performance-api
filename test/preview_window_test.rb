# frozen_string_literal: true

require_relative "test_helper"
require "date"

require_relative "../lib/portfolio_performance_api/transaction_sync"
require_relative "../lib/portfolio_performance_api/preview_window"
require_relative "../lib/portfolio_performance_api/sync_preview"

class PreviewWindowTest < Minitest::Test
  def test_shows_page_from_both_lists
    window = PortfolioPerformanceApi::PreviewWindow.new(
      %w[p0 p1 p2 p3 p4],
      %w[s0 s1 s2],
      page_size: 2
    )

    assert_equal %w[p0 p1], window.portfolio_visible
    assert_equal %w[s0 s1], window.spreadsheet_visible
    assert_equal [1, 2, 5], window.portfolio_range
    assert_equal [1, 2, 3], window.spreadsheet_range
  end

  def test_arrows_move_one_row_and_letters_page
    window = PortfolioPerformanceApi::PreviewWindow.new((0..9).map(&:to_s), (0..4).map(&:to_s), page_size: 3)

    window.down
    assert_equal 1, window.offset
    assert_equal %w[1 2 3], window.portfolio_visible
    assert_equal %w[1 2 3], window.spreadsheet_visible

    window.page_down
    assert_equal 4, window.offset
    assert_equal %w[4 5 6], window.portfolio_visible
    assert_equal %w[2 3 4], window.spreadsheet_visible

    window.page_up
    assert_equal 1, window.offset
    window.up
    assert_equal 0, window.offset
    assert_equal %w[0 1 2], window.portfolio_visible
  end

  def test_clamps_to_longer_list
    window = PortfolioPerformanceApi::PreviewWindow.new(%w[a b], (0..9).map(&:to_s), page_size: 3)
    20.times { window.down }

    assert_equal 7, window.offset
    assert_equal %w[a b], window.portfolio_visible
    assert_equal %w[7 8 9], window.spreadsheet_visible
    3.times { window.page_up }
    assert_equal 0, window.offset
  end

  def test_empty_lists
    window = PortfolioPerformanceApi::PreviewWindow.new([], [], page_size: 5)
    assert_empty window.portfolio_visible
    assert_empty window.spreadsheet_visible
    assert_equal [0, 0, 0], window.portfolio_range
    window.down
    assert_equal 0, window.offset
  end

  def test_format_record_uses_us_decimal
    record = PortfolioPerformanceApi::TransactionSync::Record.new(
      id: "x",
      account_name: "EUR",
      date: Date.new(2026, 8, 15),
      type: "REMOVAL",
      signed_cents: -9_900,
      currency: "EUR",
      description: "VISA DEBIT",
      destination: "USD1",
      uuid: "u1"
    )
    line = PortfolioPerformanceApi::SyncPreview.format_record(record, "+", width: 120)

    assert_includes line, "+  2026-08-15"
    assert_includes line, "-99.00"
    assert_includes line, "VISA DEBIT → USD1"
    refute_includes line, "-99,00"
  end

  def test_format_record_truncates_note_to_shell_width
    record = PortfolioPerformanceApi::TransactionSync::Record.new(
      id: "x",
      account_name: "EUR",
      date: Date.new(2026, 8, 15),
      type: "REMOVAL",
      signed_cents: -9_900,
      currency: "EUR",
      description: "VISA DEBIT CRYPTO TAX #{'X' * 80}",
      destination: "USD1",
      uuid: "u1"
    )
    width = 80
    line = PortfolioPerformanceApi::SyncPreview.format_record(record, "+", width: width)

    assert_equal width - PortfolioPerformanceApi::SyncPreview::ROW_INDENT, line.size
    assert_includes line, "..."
    assert_includes line, "→ USD1"
    refute_includes line, "X" * 80
  end

  def test_lines_for_prefixes_update_and_create
    date = Date.new(2026, 8, 15)
    plan = PortfolioPerformanceApi::TransactionSync::Plan.new(
      create_sheet: [record(date, 100, "New sheet", "DEPOSIT")],
      update_sheet: [record(date, -200, "Fix sheet", "FEE")],
      create_portfolio: [record(date, 300, "New port", "DEPOSIT")],
      update_portfolio: [record(date, -400, "Fix port", "REMOVAL")]
    )
    portfolio, sheet = PortfolioPerformanceApi::SyncPreview.lines_for(plan, width: 120)

    assert_equal 2, portfolio.size
    assert_equal 2, sheet.size
    assert portfolio[0].start_with?("~")
    assert portfolio[1].start_with?("+")
    assert_includes portfolio[0], "Fix port"
    assert_includes sheet[1], "New sheet"
  end

  def test_render_shows_both_section_titles
    preview = PortfolioPerformanceApi::SyncPreview.new(
      "Crypto (EUR)",
      ["+  row p"],
      ["~  row s"],
      page_size: 5,
      portfolio_counts: { create: 1, update: 0 },
      sheet_counts: { create: 0, update: 1 }
    )
    lines = preview.send(:render_lines)

    assert_equal "Crypto (EUR)", lines.first
    assert_includes lines, "PORTFOLIO  +1/~0  1-1/1"
    assert_includes lines, "SPREADSHEET  +0/~1  1-1/1"
    assert_includes lines, "  +  row p"
    assert_includes lines, "  ~  row s"
    assert_includes lines, "[Crypto (EUR)] write (S)spreadsheet, (P)ortfolio or (B)oth?"
    assert lines.last.include?("esc skip")
  end

  private

  def record(date, cents, description, type)
    PortfolioPerformanceApi::TransactionSync::Record.new(
      id: description,
      account_name: "EUR",
      date: date,
      type: type,
      signed_cents: cents,
      currency: "EUR",
      description: description,
      destination: "",
      uuid: nil
    )
  end
end
