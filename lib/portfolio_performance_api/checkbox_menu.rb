# frozen_string_literal: true

require "tty-cursor"
require "tty-prompt"
require "tty-reader"
require "tty-screen"

require_relative "checkbox_selection"

module PortfolioPerformanceApi
  class CheckboxMenu
    def initialize(labels, help: "↑/↓ navigate  space select  enter confirm  q abort")
      @labels = labels
      @help = help
      @state = CheckboxSelection.new(labels.each_index.to_a)
      @prompt = TTY::Prompt.new
      @reader = TTY::Reader.new(interrupt: :exit)
      @cursor = TTY::Cursor
      @drawn_lines = 0
    end

    def run
      raise ArgumentError, "needs an interactive terminal" unless $stdin.tty?

      $stdout.print @cursor.hide
      $stdout.sync = true
      decision = nil
      @reader.on(:keyup) { @state.up }
      @reader.on(:keydown) { @state.down }
      @reader.on(:keyspace) { @state.toggle }
      @reader.on(:keyreturn) { decision = :confirm }
      @reader.on(:keyenter) { decision = :confirm }
      @reader.on(:keypress) do |event|
        decision = :abort if %w[q Q].include?(event.value)
      end

      begin
        until decision
          draw
          @reader.read_keypress
        end
      ensure
        clear_frame
        $stdout.print @cursor.show
      end

      decision == :confirm ? @state.selected_items : []
    end

    private

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
      page_size = [TTY::Screen.height - 4, 3].max
      item_page = [page_size - 1, 1].max
      from, to = @state.visible_window(item_page)
      lines = [@help, format_row(-1, "toggle all", @state.all_selected?, @state.cursor.zero?)]
      (from..to).each do |index|
        next if index.negative?

        lines << format_row(index, @labels[index], @state.selected?(index), @state.cursor == index + 1)
      end
      lines
    end

    def format_row(_index, label, selected, current)
      marker = current ? ">" : " "
      box = selected ? "[x]" : "[ ]"
      "#{marker} #{box} #{label}"
    end
  end
end
