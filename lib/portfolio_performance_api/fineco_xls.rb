# frozen_string_literal: true

require "date"

module PortfolioPerformanceApi
  class FinecoXls
    Row = Struct.new(:date, :description, :amount_cents, :type, :raw, :security, :offset_account, keyword_init: true)

    DEFAULT_SKIP_LINES = 13
    DATE_VALUTA_HEADERS = /data[_\s-]*valuta/i
    DATE_OPERAZIONE_HEADERS = /data[_\s-]*operazione/i
    DATE_GENERIC_HEADERS = /\Adata\z/i
    DESC_HEADERS = /\Adescrizione\z/i
    DESC_COMPLETA_HEADERS = /descrizione[_\s-]*completa/i
    MONEYMAP_HEADERS = /moneymap/i
    CREDIT_HEADERS = /\Aentrate?\z/i
    DEBIT_HEADERS = /\Auscite\z/i
    AMOUNT_HEADERS = /\Aimporto\z|\Aamount\z/i

    # Fineco export columns after the preamble + header row.
    DEFAULT_COLUMNS = {
      date: 1,
      credit: 2,
      debit: 3,
      description: 4,
      description_completa: 5,
      moneymap: 7
    }.freeze

    def self.default_skip_lines
      raw = ENV["IMPORT_FINECO_XLS_SKIP_LINES"]
      raw.nil? || raw.empty? ? DEFAULT_SKIP_LINES : Integer(raw)
    end

    def self.parse(path, skip_lines: default_skip_lines)
      parse_rows(read_sheet(path), skip_lines: skip_lines)
    end

    def self.partition_excluded(rows, pattern)
      rows = Array(rows)
      return [[], rows] if pattern.to_s.empty?

      regexp = Regexp.new(pattern, Regexp::IGNORECASE)
      rows.partition { |row| row_cells(row).any? { |cell| cell.match?(regexp) } }
    end

    def self.exclude_matching(rows, pattern)
      partition_excluded(rows, pattern)[1]
    end

    def self.parse_rows(rows, skip_lines: 0)
      rows = Array(rows).drop(skip_lines)
      header_index, mapping = find_header(rows)
      body =
        if mapping
          rows[(header_index + 1)..]
        else
          mapping = DEFAULT_COLUMNS
          rows
        end
      raise ArgumentError, "Fineco XLS: header row not found (need Data_Valuta, Entrate/Uscite, Descrizione)" if mapping.nil?

      body.filter_map { |row| build_row(row, mapping) }
    end

    def self.read_sheet(path)
      bytes = File.binread(path)
      return read_html(path) if html_spreadsheet?(bytes)

      require "roo"
      require "roo-xls"
      require "zip"

      without_zip_date_warnings do
        book = Roo::Spreadsheet.open(path.to_s)
        sheet = book.sheet(0)
        (sheet.first_row..sheet.last_row).map { |index| sheet.row(index) }
      end
    end

    def self.without_zip_date_warnings
      previous = Zip.warn_invalid_date
      Zip.warn_invalid_date = false
      yield
    ensure
      Zip.warn_invalid_date = previous
    end

    def self.read_html(path)
      require "nokogiri"

      doc = Nokogiri::HTML(File.read(path))
      tables = doc.css("table").map do |table|
        table.css("tr").map { |tr| tr.css("th, td").map { |cell| cell.text.strip } }
      end
      tables.max_by(&:size) || []
    end

    def self.html_spreadsheet?(bytes)
      sample = bytes.byteslice(0, 512).to_s.b
      sample = sample.byteslice(3..) if sample.start_with?("\xEF\xBB\xBF".b)
      stripped = sample.lstrip
      stripped.start_with?("<".b) || stripped.downcase.include?("<html".b) || stripped.downcase.include?("<table".b)
    end

    def self.find_header(rows)
      rows.each_with_index do |row, index|
        labels = Array(row).map { |cell| cell.to_s.strip }
        next if labels.all?(&:empty?)

        mapping = {
          date: find_column(labels, DATE_VALUTA_HEADERS) || find_column(labels, DATE_GENERIC_HEADERS),
          description: find_column(labels, DESC_HEADERS) || find_column(labels, /\Adescriz/i),
          description_completa: find_column(labels, DESC_COMPLETA_HEADERS),
          moneymap: find_column(labels, MONEYMAP_HEADERS),
          credit: find_column(labels, CREDIT_HEADERS),
          debit: find_column(labels, DEBIT_HEADERS),
          amount: find_column(labels, AMOUNT_HEADERS)
        }
        next if mapping[:date] && labels[mapping[:date]].to_s.match?(DATE_OPERAZIONE_HEADERS)
        next unless mapping[:date] && mapping[:description]
        next unless mapping[:credit] || mapping[:debit] || mapping[:amount]

        return [index, mapping]
      end
      nil
    end

    def self.find_column(labels, pattern)
      labels.index { |label| label.match?(pattern) }
    end

    def self.build_row(row, mapping)
      cells = Array(row)
      date = parse_date(cells[mapping[:date]])
      return if date.nil?

      credit = parse_amount(cells[mapping[:credit]]) if mapping[:credit]
      debit = parse_amount(cells[mapping[:debit]]) if mapping[:debit]
      signed = parse_amount(cells[mapping[:amount]]) if mapping[:amount]

      amount_cents, type =
        if mapping[:credit] || mapping[:debit]
          if credit.to_i != 0
            [credit.abs, :DEPOSIT]
          elsif debit.to_i != 0
            [debit.abs, :REMOVAL]
          end
        elsif signed.to_i != 0
          signed.positive? ? [signed, :DEPOSIT] : [signed.abs, :REMOVAL]
        end
      return if amount_cents.nil? || amount_cents.zero?

      note = build_note(cells, mapping)
      return if note.empty?

      Row.new(date: date, description: note, amount_cents: amount_cents, type: type, raw: cells)
    end

    def self.build_note(cells, mapping)
      parts = [
        cell_text(cells, mapping[:description]),
        cell_text(cells, mapping[:description_completa])
      ]
      moneymap = cell_text(cells, mapping[:moneymap])
      parts << "Categoria: #{moneymap}" unless moneymap.empty?
      parts.reject(&:empty?).join(" ")
    end

    def self.cell_text(cells, index)
      return "" if index.nil?

      cells[index].to_s.strip
    end

    def self.parse_date(value)
      return value.to_date if date_like?(value)
      return Date.new(1899, 12, 30) + value.to_i if value.is_a?(Numeric)

      text = value.to_s.strip
      return if text.empty? || text == "-"

      begin
        Date.strptime(text, "%d/%m/%Y")
      rescue ArgumentError
        Date.parse(text)
      end
    rescue ArgumentError, TypeError
      nil
    end

    def self.date_like?(value)
      !value.is_a?(String) && value.respond_to?(:to_date) && value.respond_to?(:year)
    end

    def self.parse_amount(value)
      return 0 if value.nil? || value.to_s.strip.empty?
      return (value.to_f * 100).round if value.is_a?(Numeric)

      text = value.to_s.strip.gsub(/[€$£\s]/, "")
      text = if text.include?(",") && text.include?(".")
        text.delete(".").tr(",", ".")
      elsif text.include?(",")
        text.tr(",", ".")
      else
        text
      end
      (Float(text) * 100).round
    rescue ArgumentError
      0
    end

    def self.row_cells(row)
      cells = Array(row.raw).map { |cell| cell.to_s }
      return cells unless cells.empty?

      [row.description.to_s]
    end

    def self.matching_cells(row)
      row_cells(row)
    end
    private_class_method :read_sheet, :read_html, :html_spreadsheet?, :find_header, :find_column,
                         :build_row, :build_note, :cell_text, :parse_date, :parse_amount, :date_like?,
                         :without_zip_date_warnings
  end
end
