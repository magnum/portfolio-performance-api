# frozen_string_literal: true

module PortfolioPerformanceApi
  class CheckboxSelection
    attr_reader :cursor

    def initialize(items)
      @items = items
      @selected = Array.new(items.size, false)
      @cursor = 0
    end

    def size
      @items.size
    end

    def line_count
      size + 1
    end

    def up
      @cursor = (@cursor - 1) % line_count
    end

    def down
      @cursor = (@cursor + 1) % line_count
    end

    def toggle
      if @cursor.zero?
        toggle_all
      else
        index = @cursor - 1
        @selected[index] = !@selected[index]
      end
    end

    def toggle_all
      @selected.fill(all_selected? ? false : true)
    end

    def all_selected?
      !@selected.empty? && @selected.all?
    end

    def selected?(index)
      @selected.fetch(index)
    end

    def selected_items
      @items.each_with_index.filter_map { |item, index| item if @selected[index] }
    end

    def selected_count
      @selected.count(true)
    end

    def visible_window(page_size)
      return [0, size - 1] if size <= page_size || page_size < 1

      item_cursor = [@cursor - 1, 0].max
      start = item_cursor - (page_size / 2)
      start = 0 if start.negative?
      start = size - page_size if start + page_size > size
      [start, start + page_size - 1]
    end
  end
end
