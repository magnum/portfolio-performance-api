# frozen_string_literal: true

require "date"
require "digest"
require "securerandom"
require "time"

module PortfolioPerformanceApi
  module TransactionSync
    HEADERS = %w[date type amount currency description destination uuid].freeze
    OUTFLOW_TYPES = %w[
      PURCHASE SALE OUTBOUND_DELIVERY REMOVAL INTEREST_CHARGE TAX FEE
    ].freeze
    TYPE_ALIASES = {
      "withdrawal" => "REMOVAL",
      "prelievo" => "REMOVAL",
      "uscite" => "REMOVAL",
      "deposit" => "DEPOSIT",
      "versamento" => "DEPOSIT",
      "entrate" => "DEPOSIT",
      "transfer" => "CASH_TRANSFER",
      "trasferimento" => "CASH_TRANSFER"
    }.freeze
    DEFAULT_COLUMNS = {
      date: 0,
      type: 1,
      amount: 2,
      currency: 3,
      description: 4,
      destination: 5,
      uuid: 6
    }.freeze

    Vehicle = Struct.new(:kind, :name, :uuid, :currency, keyword_init: true)
    Record = Struct.new(
      :id, :account_name, :date, :type, :signed_cents, :currency, :description, :destination, :uuid, :row_number,
      keyword_init: true
    )
    Plan = Struct.new(:create_sheet, :create_portfolio, :update_sheet, :update_portfolio, keyword_init: true)
    Result = Struct.new(:created_sheet, :created_portfolio, :updated_sheet, :updated_portfolio, keyword_init: true)

    module_function

    def identity_id(account_name, date, signed_cents, description, destination = "")
      Digest::SHA256.hexdigest(
        [
          account_name.to_s.strip,
          date.strftime("%Y-%m-%d"),
          Integer(signed_cents).to_s,
          normalize_description(description),
          destination.to_s.strip
        ].join("\u001f")
      )
    end

    def signed_cents(type, amount_cents)
      cents = Integer(amount_cents).abs
      outflow?(type) ? -cents : cents
    end

    def outflow?(type)
      OUTFLOW_TYPES.include?(type.to_s)
    end

    def normalize_description(value)
      value.to_s.strip.gsub(/\s+/, " ")
    end

    def normalize_type(value, signed_cents = nil)
      text = value.to_s.strip
      return TYPE_ALIASES[text.downcase] if TYPE_ALIASES.key?(text.downcase)
      return text.upcase if text.match?(/\A[A-Z_]+\z/)
      return "REMOVAL" if signed_cents.to_i.negative?
      return "DEPOSIT" if signed_cents.to_i.positive?

      nil
    end

    def vehicles(client)
      currencies = client.accounts.to_h { |account| [account.uuid, account.currencyCode] }
      deposits = client.accounts.map do |account|
        Vehicle.new(kind: :deposit, name: account.name, uuid: account.uuid, currency: account.currencyCode)
      end
      securities = client.portfolios.map do |portfolio|
        reference = portfolio.has_referenceAccount? ? currencies[portfolio.referenceAccount] : nil
        currency = reference.to_s.empty? ? client.baseCurrency : reference
        currency = "EUR" if currency.to_s.empty?
        Vehicle.new(kind: :securities, name: portfolio.name, uuid: portfolio.uuid, currency: currency)
      end
      deposits + securities
    end

    def uuid_names(client)
      vehicles(client).to_h { |vehicle| [vehicle.uuid, vehicle.name] }
    end

    def name_index(client)
      vehicles(client).each_with_object({}) do |vehicle, index|
        index[vehicle.name] ||= vehicle
        index[vehicle.name.downcase] ||= vehicle
      end
    end

    def lookup_name(index, name)
      text = name.to_s.strip
      return if text.empty?

      index[text] || index[text.downcase]
    end

    def from_proto(tx, vehicle, names: {})
      vehicle = wrap_vehicle(vehicle)
      return unless belongs?(tx, vehicle)
      return unless tx.has_date?

      date = Time.at(tx.date.seconds).utc.to_date
      description = tx.has_note? ? normalize_description(tx.note) : ""
      destination = destination_name(tx, vehicle, names)
      cents = signed_cents(tx.type, tx.amount)
      Record.new(
        id: identity_id(vehicle.name, date, cents, description, destination),
        account_name: vehicle.name,
        date: date,
        type: tx.type.to_s,
        signed_cents: cents,
        currency: tx.currencyCode.to_s.empty? ? vehicle.currency : tx.currencyCode,
        description: description,
        destination: destination,
        uuid: tx.uuid
      )
    end

    def parse_sheet(raw_rows, account_name, currency:, skip_rows: 0)
      rows = Array(raw_rows)
      mapping = column_mapping(rows[skip_rows])
      rows.each_with_index.filter_map do |row, index|
        next if index < skip_rows
        next if header_row?(row)

        record = from_sheet_row(row, account_name, currency: currency, mapping: mapping)
        next unless record

        record.row_number = index + 1
        record
      end
    end

    def from_sheet_row(row, account_name, currency:, mapping: DEFAULT_COLUMNS)
      cells = Array(row)
      return if header_row?(cells)

      date = parse_date(cells[mapping[:date]])
      amount = parse_signed_cents(cells[mapping[:amount]])
      description = normalize_description(cells[mapping[:description]])
      return if date.nil? || amount.nil? || amount.zero?

      type = normalize_type(cells[mapping[:type]], amount)
      return if type.nil?

      destination = mapping[:destination] ? cells[mapping[:destination]].to_s.strip : ""
      cents = signed_cents(type, amount)
      uuid = cells[mapping[:uuid]].to_s.strip
      currency_cell = cells[mapping[:currency]].to_s.strip
      Record.new(
        id: identity_id(account_name, date, cents, description, destination),
        account_name: account_name,
        date: date,
        type: type,
        signed_cents: cents,
        currency: currency_cell.empty? ? currency : currency_cell,
        description: description,
        destination: destination,
        uuid: uuid.empty? ? nil : uuid
      )
    end

    def find_sheet_row(sheet_records, identity)
      Array(sheet_records).find { |record| record.id == identity }
    end

    def to_sheet_row(record)
      [
        record.date.strftime("%Y-%m-%d"),
        record.type,
        (record.signed_cents / 100.0).round(2),
        record.currency,
        record.description,
        record.destination.to_s,
        record.uuid.to_s
      ]
    end

    def account_plan(client, vehicle, raw_rows, names: uuid_names(client), skip_rows: 0)
      portfolio_records = client.transactions.filter_map { |tx| from_proto(tx, vehicle, names: names) }
      sheet_records = parse_sheet(raw_rows, vehicle.name, currency: vehicle.currency, skip_rows: skip_rows)
      plan(portfolio_records, sheet_records)
    end

    def split_plan(plan)
      [
        Plan.new(
          create_sheet: plan.create_sheet,
          update_sheet: plan.update_sheet,
          create_portfolio: [],
          update_portfolio: []
        ),
        Plan.new(
          create_sheet: [],
          update_sheet: [],
          create_portfolio: plan.create_portfolio,
          update_portfolio: plan.update_portfolio
        )
      ]
    end

    def plan(portfolio_records, sheet_records)
      create_sheet = []
      create_portfolio = []
      update_sheet = []
      update_portfolio = []

      Array(portfolio_records).each do |proto|
        row = find_sheet_row(sheet_records, proto.id)
        if row.nil?
          create_sheet << proto
        else
          merged = merge(proto, row)
          unless same_row?(row, merged)
            merged.row_number = row.row_number
            update_sheet << merged
          end
          update_portfolio << merged unless same_proto?(proto, merged)
        end
      end

      Array(sheet_records).each do |row|
        next if Array(portfolio_records).any? { |proto| proto.id == row.id }

        create_portfolio << row
      end

      Plan.new(
        create_sheet: create_sheet,
        create_portfolio: create_portfolio,
        update_sheet: update_sheet,
        update_portfolio: update_portfolio
      )
    end

    def apply_portfolio!(client, vehicle, records)
      vehicle = wrap_vehicle(vehicle)
      names = name_index(client)
      changed = 0
      records.each do |record|
        existing = find_transaction(client, vehicle, record, names: uuid_names(client))
        if existing
          changed += 1 if update_transaction!(existing, record, vehicle, names)
        else
          client.transactions << build_transaction(vehicle, record, names)
          changed += 1
        end
      end
      changed
    end

    def apply_sheet(sheets, title, plan, skip_rows: 0, chunk_size: 100, raw_rows: nil)
      grid = materialize_sheet(raw_rows || sheets.read_rows(title), plan, skip_rows: skip_rows)
      return [plan.create_sheet.size, plan.update_sheet.size] if grid.size <= skip_rows

      sheets.write_chunks(title, grid, start_row: skip_rows + 1, chunk_size: chunk_size)
      [plan.create_sheet.size, plan.update_sheet.size]
    end

    def materialize_sheet(raw_rows, plan, skip_rows: 0)
      source = Array(raw_rows)
      grid = Array.new([source.size, skip_rows + 1].max) { |index| Array(source[index]).dup }
      grid[skip_rows] = HEADERS.dup

      Array(plan.update_sheet).each do |record|
        index = record.row_number.to_i - 1
        next if index.negative?

        grid << [] while grid.size <= index
        grid[index] = to_sheet_row(record)
      end
      Array(plan.create_sheet).each do |record|
        grid << to_sheet_row(record)
      end
      grid
    end

    def sheet_chunks(grid, start_row:, chunk_size:)
      data = Array(grid)[(start_row - 1)..]
      return [] if data.nil? || data.empty?

      size = [Integer(chunk_size), 1].max
      data.each_slice(size).map.with_index do |slice, index|
        first = start_row + (index * size)
        { start_row: first, end_row: first + slice.size - 1, values: slice }
      end
    end

    def column_mapping(header)
      labels = Array(header).map { |cell| cell.to_s.strip.downcase }
      return DEFAULT_COLUMNS unless header_row?(labels)

      {
        date: labels.index("date") || DEFAULT_COLUMNS[:date],
        type: labels.index("type") || DEFAULT_COLUMNS[:type],
        amount: labels.index("amount") || DEFAULT_COLUMNS[:amount],
        currency: labels.index("currency") || DEFAULT_COLUMNS[:currency],
        description: labels.index("description") || DEFAULT_COLUMNS[:description],
        destination: destination_column(labels),
        uuid: labels.index("uuid") || DEFAULT_COLUMNS[:uuid]
      }
    end

    def parse_date(value)
      return value.to_date if value.respond_to?(:to_date) && !value.is_a?(String)

      text = value.to_s.strip
      return if text.empty?

      Date.iso8601(text)
    rescue ArgumentError
      begin
        Date.strptime(text, "%d/%m/%Y")
      rescue ArgumentError
        Date.parse(text)
      end
    rescue ArgumentError, TypeError
      nil
    end

    def header_row?(cells)
      labels = Array(cells).map { |cell| cell.to_s.strip.downcase }
      labels.include?("date") && (labels.include?("amount") || labels.include?("type"))
    end

    def parse_signed_cents(value)
      return if value.nil? || value.to_s.strip.empty?
      return (value.to_f * 100).round if value.is_a?(Numeric)

      text = value.to_s.strip.gsub(/[€$£\s]/, "")
      last_comma = text.rindex(",")
      last_dot = text.rindex(".")
      text = if last_comma && last_dot
        if last_comma > last_dot
          text.delete(".").tr(",", ".")
        else
          text.delete(",")
        end
      elsif text.count(",") > 1
        text.delete(",")
      elsif text.include?(",")
        text.tr(",", ".")
      else
        text
      end
      (Float(text) * 100).round
    rescue ArgumentError
      nil
    end

    def wrap_vehicle(vehicle)
      return vehicle if vehicle.is_a?(Vehicle)
      return vehicle if vehicle.respond_to?(:kind) && vehicle.respond_to?(:currency)

      if vehicle.respond_to?(:currencyCode)
        Vehicle.new(kind: :deposit, name: vehicle.name, uuid: vehicle.uuid, currency: vehicle.currencyCode)
      else
        Vehicle.new(kind: :securities, name: vehicle.name, uuid: vehicle.uuid, currency: "EUR")
      end
    end

    def belongs?(tx, vehicle)
      if vehicle.kind == :securities
        (tx.has_portfolio? && tx.portfolio == vehicle.uuid) ||
          (tx.has_otherPortfolio? && tx.otherPortfolio == vehicle.uuid)
      else
        (tx.has_account? && tx.account == vehicle.uuid) ||
          (tx.has_otherAccount? && tx.otherAccount == vehicle.uuid)
      end
    end

    def destination_name(tx, vehicle, names)
      other_uuid =
        if vehicle.uuid == (tx.has_account? ? tx.account : nil)
          (tx.has_otherAccount? && tx.otherAccount) ||
            (tx.has_otherPortfolio? && tx.otherPortfolio) ||
            (tx.has_portfolio? && tx.portfolio)
        elsif vehicle.uuid == (tx.has_otherAccount? ? tx.otherAccount : nil)
          tx.has_account? ? tx.account : nil
        elsif vehicle.uuid == (tx.has_portfolio? ? tx.portfolio : nil)
          (tx.has_otherPortfolio? && tx.otherPortfolio) ||
            (tx.has_otherAccount? && tx.otherAccount) ||
            (tx.has_account? && tx.account)
        elsif vehicle.uuid == (tx.has_otherPortfolio? ? tx.otherPortfolio : nil)
          tx.has_portfolio? ? tx.portfolio : nil
        end
      names[other_uuid].to_s
    end

    def destination_column(labels)
      labels.index { |label| label.match?(/destination|destinat|offset|other/) }
    end

    def merge(proto, row)
      Record.new(
        id: proto.id,
        account_name: proto.account_name,
        date: proto.date,
        type: row.type || proto.type,
        signed_cents: proto.signed_cents,
        currency: proto.currency,
        description: proto.description,
        destination: row.destination.to_s.empty? ? proto.destination : row.destination,
        uuid: proto.uuid.to_s.empty? ? row.uuid : proto.uuid,
        row_number: row.row_number
      )
    end

    def same_row?(row, merged)
      row.type == merged.type &&
        row.currency == merged.currency &&
        row.uuid.to_s == merged.uuid.to_s &&
        row.description == merged.description &&
        row.destination.to_s == merged.destination.to_s &&
        row.signed_cents == merged.signed_cents &&
        row.date == merged.date
    end

    def same_proto?(proto, merged)
      proto.type == merged.type &&
        proto.uuid.to_s == merged.uuid.to_s &&
        proto.destination.to_s == merged.destination.to_s
    end

    def find_transaction(client, vehicle, record, names: {})
      if record.uuid.to_s != ""
        found = client.transactions.find { |tx| tx.uuid == record.uuid }
        return found if found
      end

      client.transactions.find do |tx|
        mapped = from_proto(tx, vehicle, names: names)
        mapped && mapped.id == record.id
      end
    end

    def update_transaction!(tx, record, vehicle, names)
      changed = false
      if tx.type.to_s != record.type
        tx.type = record.type
        changed = true
      end
      amount = record.signed_cents.abs
      if tx.amount != amount
        tx.amount = amount
        changed = true
      end
      if record.uuid.to_s != "" && tx.uuid != record.uuid
        tx.uuid = record.uuid
        changed = true
      end
      changed || assign_counterpart!(tx, vehicle, record, names)
    end

    def build_transaction(vehicle, record, names)
      now = Time.now.utc
      date = Time.utc(record.date.year, record.date.month, record.date.day)
      tx = Proto::PTransaction.new(
        uuid: record.uuid.to_s.empty? ? SecureRandom.uuid : record.uuid,
        type: record.type,
        date: Google::Protobuf::Timestamp.new(seconds: date.to_i),
        currencyCode: record.currency.to_s.empty? ? vehicle.currency : record.currency,
        amount: record.signed_cents.abs,
        shares: 0,
        note: record.description,
        updatedAt: Google::Protobuf::Timestamp.new(seconds: now.to_i, nanos: now.nsec)
      )
      if vehicle.kind == :securities
        tx.portfolio = vehicle.uuid
      else
        tx.account = vehicle.uuid
      end
      assign_counterpart!(tx, vehicle, record, names)
      tx
    end

    def assign_counterpart!(tx, vehicle, record, names)
      dest = lookup_name(names, record.destination)
      return false unless dest

      before = [tx.has_account? && tx.account, tx.has_otherAccount? && tx.otherAccount,
                tx.has_portfolio? && tx.portfolio, tx.has_otherPortfolio? && tx.otherPortfolio]
      if vehicle.kind == :deposit && dest.kind == :deposit
        tx.otherAccount = dest.uuid
      elsif vehicle.kind == :deposit && dest.kind == :securities
        tx.portfolio = dest.uuid
      elsif vehicle.kind == :securities && dest.kind == :securities
        tx.otherPortfolio = dest.uuid
      elsif vehicle.kind == :securities && dest.kind == :deposit
        tx.account = dest.uuid
      end
      after = [tx.has_account? && tx.account, tx.has_otherAccount? && tx.otherAccount,
               tx.has_portfolio? && tx.portfolio, tx.has_otherPortfolio? && tx.otherPortfolio]
      before != after
    end
    private_class_method :merge, :same_row?, :same_proto?, :find_transaction,
                         :update_transaction!, :build_transaction, :wrap_vehicle, :belongs?,
                         :destination_name, :destination_column, :assign_counterpart!, :lookup_name
  end
end
