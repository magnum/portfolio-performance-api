# frozen_string_literal: true

require_relative "test_helper"
require "date"

require_relative "../lib/portfolio_performance_api/fineco_xls"
require_relative "../lib/portfolio_performance_api/fineco_import"

class ImportMatchRuleTest < Minitest::Test
  include PortfolioFixtures

  def test_parse_capture_group_and_fixed_value
    captured = PortfolioPerformanceApi::FinecoImport::Match.parse("/Compravendita Titoli (.+?) Qta/")
    assert_equal "", captured.fixed
    assert_equal "AMAZON.COM", captured.extract(["Compravendita Titoli AMAZON.COM Qta/Val.nom. 20"])

    fixed = PortfolioPerformanceApi::FinecoImport::Match.parse("/Compravendita Divise/EUR010069756")
    assert_equal "EUR010069756", fixed.fixed
    assert_equal "EUR010069756", fixed.extract(["Cambio valuta Compravendita Divise"])
    assert_nil fixed.extract(["Stipendio"])
  end

  def test_parse_wraps_spec_without_slashes_then_rejects_if_no_value
    error = assert_raises(ArgumentError) do
      PortfolioPerformanceApi::FinecoImport::Match.parse("Compravendita Divise", flag: "--match-offset-account")
    end
    assert_includes error.message, "--match-offset-account"
  end

  def test_parse_rejects_empty_and_empty_regexp
    assert_raises(ArgumentError) { PortfolioPerformanceApi::FinecoImport::Match.parse("") }
    assert_raises(ArgumentError) { PortfolioPerformanceApi::FinecoImport::Match.parse("//EUR") }
  end

  def test_parse_keeps_slash_inside_regexp_when_value_follows
    rule = PortfolioPerformanceApi::FinecoImport::Match.parse("/Qta\\/Val\\.nom\\./titoli")
    assert_equal "titoli", rule.fixed
    assert_equal "titoli", rule.extract(["Qta/Val.nom. 10"])
  end

  def test_extract_is_case_insensitive_and_uses_first_cell
    rule = PortfolioPerformanceApi::FinecoImport::Match.parse("/compravendita titoli (.+?) qta/")
    assert_equal "VWCE", rule.extract(["note", "COMPRAVENDITA TITOLI VWCE Qta/Val.nom. 1"])
  end

  def test_extract_skips_blank_capture_and_falls_back_to_fixed
    rule = PortfolioPerformanceApi::FinecoImport::Match.parse("/Titoli (\\s*)Qta/FALLBACK")
    assert_equal "FALLBACK", rule.extract(["Titoli  Qta"])
  end

  def test_named_capture_counts_as_capturing
    rule = PortfolioPerformanceApi::FinecoImport::Match.parse("/Titoli (?<name>.+?) Qta/")
    assert rule.capturing?
    assert_equal "VWCE", rule.extract(["Titoli VWCE Qta"])
  end

  def test_non_capturing_group_needs_fixed_value
    error = assert_raises(ArgumentError) do
      PortfolioPerformanceApi::FinecoImport::Match.parse("/Titoli (?:VWCE)/")
    end
    assert_includes error.message, "capture group"
  end

  def test_row_matcher_first_rule_wins_and_does_not_overwrite
    buy = row("Compravendita Titoli AMAZON.COM Qta/Val.nom. 20,000000")
    buy.security = "KEEP"
    preset = row("Compravendita Titoli VWCE Qta/Val.nom. 1")
    other = row("Stipendio")

    PortfolioPerformanceApi::FinecoImport.apply_matches!(
      [buy, preset, other],
      ["/Compravendita Titoli (.+?) Qta/", "/Titoli (.+)$/"],
      ["/Compravendita Titoli/fineco00109494", "/Divise/EUR"]
    )

    assert_equal "KEEP", buy.security
    assert_equal "fineco00109494", buy.offset_account
    assert_equal "VWCE", preset.security
    assert_nil other.security
    assert_nil other.offset_account
  end

  def test_row_matcher_validate_unknown_security_and_cash_offset_for_buy
    client = protobuf_client
    error = assert_raises(ArgumentError) do
      PortfolioPerformanceApi::FinecoImport.validate_matches!(client, [row("x", security: "AMAZON.COM")])
    end
    assert_includes error.message, "security not found"

    error = assert_raises(ArgumentError) do
      PortfolioPerformanceApi::FinecoImport.validate_matches!(client, [row("x", offset_account: "USD010069756")])
    end
    assert_includes error.message, "offset account not found"

    error = assert_raises(ArgumentError) do
      PortfolioPerformanceApi::FinecoImport.validate_matches!(client, [row("x", security: "VWCE", offset_account: "Risparmio")])
    end
    assert_includes error.message, "securities account"
  end

  def test_row_matcher_validate_accepts_known_security_and_securities_offset
    client = protobuf_client
    row = row("x", security: "VWCE", offset_account: "Deposito titoli")

    PortfolioPerformanceApi::FinecoImport.validate_matches!(client, [row])
  end

  private

  def row(description, security: nil, offset_account: nil)
    PortfolioPerformanceApi::FinecoXls::Row.new(
      date: Date.new(2026, 8, 15),
      description: description,
      amount_cents: 1_000,
      type: :REMOVAL,
      raw: [description],
      security: security,
      offset_account: offset_account
    )
  end
end
