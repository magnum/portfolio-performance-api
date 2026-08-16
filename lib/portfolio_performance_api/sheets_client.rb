# frozen_string_literal: true

require "json"
require "uri"

module PortfolioPerformanceApi
  class SheetsClient
    SPREADSHEET_URI = "https://sheets.googleapis.com/v4/spreadsheets/%s"
    DATA_RANGE = "A:G"

    def initialize(session:, spreadsheet_id:)
      raise NotConfigured, "SYNC_GOOGLE_DRIVE_FILE_ID is not configured" if spreadsheet_id.to_s.empty?

      @session = session
      @spreadsheet_id = spreadsheet_id
    end

    def sheet_titles
      uri = URI(format(SPREADSHEET_URI, @spreadsheet_id))
      uri.query = URI.encode_www_form("fields" => "sheets.properties.title")
      payload = JSON.parse(@session.api_request(uri).body)
      Array(payload["sheets"]).map { |sheet| sheet.dig("properties", "title") }
    end

    def ensure_sheet(title, known_titles: nil)
      titles = known_titles || sheet_titles
      return title if titles.include?(title)

      batch_update([{ addSheet: { properties: { title: title } } }])
      title
    end

    def sheet_properties
      uri = URI(format(SPREADSHEET_URI, @spreadsheet_id))
      uri.query = URI.encode_www_form("fields" => "sheets.properties(sheetId,title)")
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
      TransactionSync.sheet_chunks(grid, start_row: start_row, chunk_size: chunk_size).each do |chunk|
        write_range(title, "A#{chunk[:start_row]}:G#{chunk[:end_row]}", chunk[:values])
      end
    end

    def clear_sheet(title)
      uri = URI("#{format(SPREADSHEET_URI, @spreadsheet_id)}/values/#{encode_range(title, "A:Z")}:clear")
      with_retry do
        @session.api_request(uri, method: :post, body: "{}")
      end
    end

    def self.quote_sheet(title)
      "'#{title.to_s.gsub("'", "''")}'"
    end

    def self.sanitize_title(name)
      title = name.to_s.gsub(%r{[:\\/?*\[\]]}, "-").strip
      title = "Account" if title.empty?
      title[0, 100]
    end

    def self.unique_titles(names)
      used = {}
      Array(names).map do |name|
        base = sanitize_title(name)
        title = base
        index = 2
        while used[title]
          suffix = " (#{index})"
          title = "#{base[0, [100 - suffix.size, 1].max]}#{suffix}"
          index += 1
        end
        used[title] = true
        title
      end
    end

    private

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
