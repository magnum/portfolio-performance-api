# frozen_string_literal: true

module PortfolioPerformanceApi
  class PreviewWindow
    attr_reader :offset, :page_size, :lists

    def initialize(lists, page_size:, page_sizes: nil, locked: nil)
      @lists = Array(lists).map { |list| Array(list) }
      raise ArgumentError, "preview needs at least one list" if @lists.empty?

      @page_size = [Integer(page_size), 1].max
      @page_sizes = Array(page_sizes)
      @locked = Array(locked)
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

    def visible(index = 0)
      slice(index)
    end

    def range(index = 0)
      range_for(index)
    end

    def page_size_at(index)
      size = @page_sizes[Integer(index)]
      return @page_size if size.nil?

      [Integer(size), 1].max
    end

    def max_offset
      @lists.each_index.map { |index| list_max_offset(index) }.max
    end

    private

    def locked?(index)
      @locked[Integer(index)] == true
    end

    def list_at(index)
      @lists.fetch(Integer(index))
    end

    def move(delta)
      @offset = [[@offset + delta, 0].max, max_offset].min
    end

    def slice(index)
      lines = list_at(index)
      return [] if lines.empty?

      lines[start_index(index), page_size_at(index)]
    end

    def start_index(index)
      return 0 if locked?(index)

      [@offset, last_start(index)].min
    end

    def last_start(index)
      [0, list_at(index).size - page_size_at(index)].max
    end

    def list_max_offset(index)
      return 0 if locked?(index)

      [0, list_at(index).size - page_size_at(index)].max
    end

    def range_for(index)
      visible_rows = slice(index)
      lines = list_at(index)
      return [0, 0, lines.size] if visible_rows.empty?

      from = start_index(index) + 1
      [from, from + visible_rows.size - 1, lines.size]
    end
  end
end
