# frozen_string_literal: true

require "tty-cursor"
require "tty-prompt"
require "tty-reader"
require "tty-screen"

require_relative "preview_window"

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
      @account_name = account_name
      page = [Integer(page_size), 1].max
      if $stdin.tty?
        usable = [TTY::Screen.height - 5, 4].max
        page = [page, usable / 2].min
      end
      @window = PreviewWindow.new(portfolio_lines, spreadsheet_lines, page_size: page)
      @portfolio_counts = portfolio_counts
      @sheet_counts = sheet_counts
      @prompt = TTY::Prompt.new
      @reader = TTY::Reader.new(interrupt: :exit)
      @cursor = TTY::Cursor
      @drawn_lines = 0
    end

    def run
      return static_choice unless $stdin.tty?

      $stdout.print @cursor.hide
      $stdout.sync = true
      choice = nil
      @reader.on(:keyup) { @window.up }
      @reader.on(:keydown) { @window.down }
      @reader.on(:keyescape) { choice = "N" }
      @reader.on(:keypress) do |event|
        choice = key_choice(event)
        @window.page_up if %w[u U].include?(event.value)
        @window.page_down if %w[v V].include?(event.value)
      end

      begin
        until choice
          draw
          @reader.read_keypress
        end
      ensure
        clear_frame
        $stdout.print @cursor.show
      end

      choice
    end

    private

    def static_choice
      render_lines.each { |line| $stdout.puts line }
      loop do
        $stderr.print "[#{@account_name}] write (S)spreadsheet, (P)ortfolio or (B)oth? "
        answer = $stdin.gets.to_s.strip.upcase
        return answer if %w[S P B].include?(answer)
        return "N" if answer.empty? || answer == "\e"

        warn "type S, P, B or press Esc to skip"
      end
    end

    def key_choice(event)
      return "N" if event.key&.name == :escape || event.value == "\e"
      return event.value.upcase if %w[s S p P b B].include?(event.value)

      nil
    end

    def draw
      lines = render_lines
      clear_frame
      lines.each { |line| $stdout.puts line }
      @drawn_lines = lines.size
    end

    def clear_frame
      return if @drawn_lines.zero?

      $stdout.print @cursor.up(@drawn_lines)
      @drawn_lines.times do
        $stdout.print @cursor.clear_line
        $stdout.print @cursor.next_line
      end
      $stdout.print @cursor.up(@drawn_lines)
      @drawn_lines = 0
    end

    def render_lines
      [
        @account_name,
        section("PORTFOLIO", @window.portfolio_visible, @window.portfolio_range, @portfolio_counts),
        section("SPREADSHEET", @window.spreadsheet_visible, @window.spreadsheet_range, @sheet_counts),
        "[#{@account_name}] write (S)spreadsheet, (P)ortfolio or (B)oth?",
        "↑/↓ row  u/v page ±#{@window.page_size}  esc skip"
      ].flatten
    end

    def section(title, rows, range, counts)
      from, to, total = range
      summary = "+#{counts.fetch(:create, 0)}/~#{counts.fetch(:update, 0)}"
      label = if total.positive?
        "#{title}  #{summary}  #{from}-#{to}/#{total}"
      else
        "#{title}  #{summary}"
      end
      [label] + (rows.empty? ? ["  (none)"] : rows.map { |row| "  #{row}" })
    end
  end
end
