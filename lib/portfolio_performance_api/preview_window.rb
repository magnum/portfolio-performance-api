# frozen_string_literal: true

module PortfolioPerformanceApi
  class PreviewWindow
    attr_reader :offset, :page_size, :portfolio_lines, :spreadsheet_lines

    def initialize(portfolio_lines, spreadsheet_lines, page_size:)
      @portfolio_lines = Array(portfolio_lines)
      @spreadsheet_lines = Array(spreadsheet_lines)
      @page_size = [Integer(page_size), 1].max
      @offset = 0
    end

    def up
      move(-1)
    end

    def down
      move(1)
    end

    def page_up
      move(-@page_size)
    end

    def page_down
      move(@page_size)
    end

    def portfolio_visible
      slice(@portfolio_lines)
    end

    def spreadsheet_visible
      slice(@spreadsheet_lines)
    end

    def portfolio_range
      range(@portfolio_lines)
    end

    def spreadsheet_range
      range(@spreadsheet_lines)
    end

    def max_offset
      [0, [@portfolio_lines.size, @spreadsheet_lines.size].max - @page_size].max
    end

    private

    def move(delta)
      @offset = [[@offset + delta, 0].max, max_offset].min
    end

    def slice(lines)
      return [] if lines.empty?

      lines[start_index(lines), @page_size]
    end

    def start_index(lines)
      [@offset, last_start(lines)].min
    end

    def last_start(lines)
      [0, lines.size - @page_size].max
    end

    def range(lines)
      visible = slice(lines)
      return [0, 0, lines.size] if visible.empty?

      from = start_index(lines) + 1
      [from, from + visible.size - 1, lines.size]
    end
  end
end
