# frozen_string_literal: true

require "json"
require "uri"

module PortfolioPerformanceApi
  class SheetsClient
    SPREADSHEET_URI = "https://sheets.googleapis.com/v4/spreadsheets/%s"
    EDIT_URI = "https://docs.google.com/spreadsheets/d/%s/edit"
    DEPOSIT_PREFIX = "deposit - "
    SECURITIES_PREFIX = "securities - "
    TITLE_MAX = 100

    attr_reader :spreadsheet_id

    def initialize(session:, spreadsheet_id:)
      raise NotConfigured, "SYNC_GOOGLE_DRIVE_FILE_ID is not configured" if spreadsheet_id.to_s.empty?

      @session = session
      @spreadsheet_id = spreadsheet_id
    end

    def sheet_titles
      sheet_properties.map { |props| props["title"] }
    end

    def sheet_gids
      sheet_properties.to_h { |props| [props["title"], props["sheetId"]] }
    end

    def ensure_sheet(title, known_titles: nil)
      titles = known_titles || sheet_titles
      return title if titles.include?(title)

      batch_update([{ addSheet: { properties: { title: title } } }])
      title
    end

    def sheet_properties
      uri = URI(format(SPREADSHEET_URI, @spreadsheet_id))
      uri.query = URI.encode_www_form("fields" => "sheets.properties(sheetId,title,gridProperties(rowCount,columnCount))")
      payload = JSON.parse(@session.api_request(uri).body)
      Array(payload["sheets"]).map { |sheet| sheet["properties"] || {} }
    end

    def reset_sheets(titles)
      wanted = Array(titles)
      raise ArgumentError, "reset_sheets needs at least one title" if wanted.empty?

      current = sheet_properties
      existing = current.map { |props| props["title"] }
      requests = []
      wanted.each do |title|
        next if existing.include?(title)

        requests << { addSheet: { properties: { title: title } } }
      end
      current.each do |props|
        next if wanted.include?(props["title"])

        requests << { deleteSheet: { sheetId: props["sheetId"] } }
      end
      batch_update(requests) unless requests.empty?
      wanted.each { |title| clear_sheet(title) }
    end

    def read_rows(title)
      uri = URI("#{format(SPREADSHEET_URI, @spreadsheet_id)}/values/#{encode_range(title, "A:Z")}")
      uri.query = URI.encode_www_form(
        "valueRenderOption" => "UNFORMATTED_VALUE",
        "dateTimeRenderOption" => "FORMATTED_STRING",
        "majorDimension" => "ROWS"
      )
      payload = JSON.parse(@session.api_request(uri).body)
      Array(payload["values"])
    end

    def write_chunks(title, grid, start_row:, chunk_size: 100)
      chunks = TransactionSync.sheet_chunks(grid, start_row: start_row, chunk_size: chunk_size)
      return if chunks.empty?

      ensure_row_count(title, chunks.last[:end_row])
      chunks.each do |chunk|
        write_range(title, "A#{chunk[:start_row]}:G#{chunk[:end_row]}", chunk[:values])
      end
    end

    def clear_sheet(title)
      uri = URI("#{format(SPREADSHEET_URI, @spreadsheet_id)}/values/#{encode_range(title, "A:Z")}:clear")
      with_retry do
        @session.api_request(uri, method: :post, body: "{}")
      end
    end

    def clear_data_rows(title, skip_rows: 0)
      start_row = Integer(skip_rows) + 2
      uri = URI("#{format(SPREADSHEET_URI, @spreadsheet_id)}/values/#{encode_range(title, "A#{start_row}:Z")}:clear")
      with_retry do
        @session.api_request(uri, method: :post, body: "{}")
      end
    end

    def self.spreadsheet_url(spreadsheet_id, gid: nil)
      url = format(EDIT_URI, spreadsheet_id)
      return url if gid.nil? || gid.to_s.empty?

      "#{url}?gid=#{gid}#gid=#{gid}"
    end

    def self.terminal_link(text, url)
      label = text.to_s
      return label if url.to_s.empty?

      "\e]8;;#{url}\e\\#{label}\e]8;;\e\\"
    end

    def self.quote_sheet(title)
      "'#{title.to_s.gsub("'", "''")}'"
    end

    def self.prefix_for(kind)
      kind.to_s == "securities" ? SECURITIES_PREFIX : DEPOSIT_PREFIX
    end

    def self.sheet_kind(title)
      text = title.to_s
      return :securities if text.downcase.start_with?(SECURITIES_PREFIX)
      return :deposit if text.downcase.start_with?(DEPOSIT_PREFIX)

      nil
    end

    def self.account_name(title)
      text = title.to_s
      prefix = prefix_for(sheet_kind(text)) if sheet_kind(text)
      return text unless prefix && text.downcase.start_with?(prefix.downcase)

      text[prefix.size..]
    end

    def self.sheet_title(kind, name)
      prefix = prefix_for(kind)
      "#{prefix}#{sanitize_title(name, max: TITLE_MAX - prefix.size)}"
    end

    def self.sanitize_title(name, max: TITLE_MAX)
      title = name.to_s.gsub(%r{[:\\/?*\[\]]}, "-").strip
      title = "Account" if title.empty?
      title[0, max]
    end

    def self.unique_titles(vehicles)
      used = {}
      Array(vehicles).map do |vehicle|
        kind, name = kind_and_name(vehicle)
        prefix = prefix_for(kind)
        title = sheet_title(kind, name)
        index = 2
        while used[title]
          suffix = " (#{index})"
          name_max = [TITLE_MAX - prefix.size - suffix.size, 1].max
          title = "#{prefix}#{sanitize_title(name, max: name_max)}#{suffix}"
          index += 1
        end
        used[title] = true
        title
      end
    end

    def self.kind_and_name(vehicle)
      if vehicle.respond_to?(:kind) && vehicle.respond_to?(:name)
        [vehicle.kind, vehicle.name]
      else
        [:deposit, vehicle.to_s]
      end
    end
    private_class_method :kind_and_name

    private

    def ensure_row_count(title, rows)
      props = sheet_properties.find { |item| item["title"] == title }
      return unless props

      current = Integer(props.dig("gridProperties", "rowCount") || 0)
      needed = Integer(rows)
      return if needed <= current

      batch_update(
        [
          {
            updateSheetProperties: {
              properties: {
                sheetId: props["sheetId"],
                gridProperties: { rowCount: needed }
              },
              fields: "gridProperties.rowCount"
            }
          }
        ]
      )
    end

    def batch_update(requests)
      uri = URI("#{format(SPREADSHEET_URI, @spreadsheet_id)}:batchUpdate")
      with_retry do
        @session.api_request(uri, method: :post, body: { requests: requests }.to_json)
      end
    end

    def write_range(title, cells, values)
      uri = URI("#{format(SPREADSHEET_URI, @spreadsheet_id)}/values/#{encode_range(title, cells)}")
      uri.query = URI.encode_www_form("valueInputOption" => "RAW")
      with_retry do
        @session.api_request(
          uri,
          method: :put,
          body: { range: "#{quote_sheet(title)}!#{cells}", majorDimension: "ROWS", values: values }.to_json
        )
      end
    end

    def with_retry
      attempts = 0
      begin
        yield
      rescue DriveError => error
        attempts += 1
        raise unless error.message.include?("429") && attempts <= 4

        delay = [20, 40, 60, 60][attempts - 1]
        warn "Sheets quota hit, retrying in #{delay}s..."
        sleep delay
        retry
      end
    end

    def encode_range(title, cells)
      URI.encode_www_form_component("#{self.class.quote_sheet(title)}!#{cells}")
    end

    def quote_sheet(title)
      self.class.quote_sheet(title)
    end
  end
end
