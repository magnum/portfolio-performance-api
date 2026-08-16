# frozen_string_literal: true

require "tty-screen"

require_relative "row_preview"

module PortfolioPerformanceApi
  class SyncPreview
    ROW_INDENT = 2
    ELLIPSIS = "..."

    def self.format_record(record, action, width: TTY::Screen.width)
      amount = format("%.2f", (record.signed_cents / 100.0).round(2))
      prefix = "#{action}  #{record.date}  #{record.type.to_s.ljust(16)}  #{amount.rjust(10)}  #{record.currency}  "
      dest = record.destination.to_s.empty? ? "" : " → #{record.destination}"
      available = [Integer(width) - ROW_INDENT - prefix.size, 0].max
      "#{prefix}#{fit_note(record.description.to_s, dest, available)}"
    end

    def self.lines_for(plan, width: TTY::Screen.width)
      portfolio = Array(plan.update_portfolio).map { |record| format_record(record, "~", width: width) } +
                  Array(plan.create_portfolio).map { |record| format_record(record, "+", width: width) }
      spreadsheet = Array(plan.update_sheet).map { |record| format_record(record, "~", width: width) } +
                    Array(plan.create_sheet).map { |record| format_record(record, "+", width: width) }
      [portfolio, spreadsheet]
    end

    def self.fit_note(note, dest, available)
      if dest.size >= available
        truncate(dest, available)
      else
        "#{truncate(note, available - dest.size)}#{dest}"
      end
    end

    def self.truncate(text, max)
      return "" if max <= 0
      return text if text.length <= max
      return ELLIPSIS[0, max] if max <= ELLIPSIS.size

      "#{text[0, max - ELLIPSIS.size]}#{ELLIPSIS}"
    end
    private_class_method :fit_note, :truncate

    def initialize(account_name, portfolio_lines, spreadsheet_lines, page_size:,
                   portfolio_counts:, sheet_counts:)
      @preview = RowPreview.new(
        account_name,
        [
          RowPreview::Section.new(title: "PORTFOLIO", lines: portfolio_lines, counts: portfolio_counts),
          RowPreview::Section.new(title: "SPREADSHEET", lines: spreadsheet_lines, counts: sheet_counts)
        ],
        page_size: page_size,
        prompt: "[#{account_name}] write (S)spreadsheet, (P)ortfolio or (B)oth?",
        choices: %w[S P B]
      )
    end

    def run
      @preview.run
    end
  end
end
