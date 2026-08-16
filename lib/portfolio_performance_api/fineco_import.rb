# frozen_string_literal: true

require "securerandom"
require "time"

require_relative "transaction_identity"
require_relative "transaction_sync"
require_relative "fineco_xls"

module PortfolioPerformanceApi
  module FinecoImport
    DEFAULT_SECURITY_SPEC = "/Compravendita Titoli\\s+(.+?)\\s+Qta/"
    CROSS_ENTRY_TYPES = %w[CASH_TRANSFER PURCHASE SALE SECURITY_TRANSFER].freeze

    module_function

    def find_account(client, name)
      text = name.to_s.strip
      return if text.empty?

      accounts = client.accounts.select { |account| account.name == text }
      accounts = client.accounts.select { |account| account.name.casecmp?(text) } if accounts.empty?
      accounts = client.accounts.select { |account| account.uuid == text } if accounts.empty?
      accounts.first
    end

    def find_security(client, name)
      securities = client.securities.select { |security| security.name == name }
      securities = client.securities.select { |security| security.name.casecmp?(name) } if securities.empty?
      securities = client.securities.select { |security| security.uuid == name } if securities.empty?
      securities.first
    end

    def find_vehicle(client, name, kind: nil)
      text = name.to_s.strip
      return if text.empty?

      vehicles = TransactionSync.vehicles(client)
      vehicles = vehicles.select { |vehicle| vehicle.kind == kind } if kind
      vehicles.find { |vehicle| vehicle.name == text } ||
        vehicles.find { |vehicle| vehicle.name.casecmp?(text) } ||
        vehicles.find { |vehicle| vehicle.uuid == text }
    end

    def last_transaction_date(client, account_uuid)
      client.transactions.filter_map do |tx|
        next unless tx.has_account? && tx.account == account_uuid
        next unless tx.has_date?

        Time.at(tx.date.seconds).utc.to_date
      end.max
    end

    def compile_regexp(pattern)
      text = pattern.to_s.strip
      raise ArgumentError, "empty regexp" if text.empty?

      Regexp.new(text, Regexp::IGNORECASE)
    end

    def parse_match_spec(spec, flag: "--match")
      text = spec.to_s.strip
      raise ArgumentError, "invalid #{flag} #{spec.inspect} (expected /REGEXP/ or /REGEXP/VALUE)" if text.empty?

      text = "/#{text}/" unless text.start_with?("/")
      match = text.match(/\A\/(.*)\/(.*)\z/m)
      if match.nil? || match[1].empty?
        raise ArgumentError, "invalid #{flag} #{spec.inspect} (expected /REGEXP/ or /REGEXP/VALUE)"
      end

      regexp = compile_regexp(match[1])
      fixed = match[2].strip
      unless capturing?(regexp) || !fixed.empty?
        raise ArgumentError, "invalid #{flag} #{spec.inspect} (need a capture group or /REGEXP/VALUE)"
      end

      [regexp, fixed]
    end

    def parse_offset_spec(spec)
      parse_match_spec(spec, flag: "--match-offset-account")
    end

    def apply_matches!(rows, security_specs, offset_specs)
      securities = Array(security_specs).filter_map do |spec|
        next if spec.to_s.strip.empty?

        parse_match_spec(spec, flag: "--match-security")
      end
      offsets = Array(offset_specs).map do |spec|
        parse_match_spec(spec, flag: "--match-offset-account")
      end

      Array(rows).each do |row|
        cells = FinecoXls.row_cells(row)
        if row.security.to_s.empty?
          securities.each do |regexp, fixed|
            value = value_from_cells(cells, regexp, fixed)
            next unless value

            row.security = value
            break
          end
        end
        next unless row.offset_account.to_s.empty?

        offsets.each do |regexp, fixed|
          value = value_from_cells(cells, regexp, fixed)
          next unless value

          row.offset_account = value
          break
        end
      end
      rows
    end

    def value_from_cells(cells, regexp, fixed = "")
      Array(cells).each do |cell|
        match = regexp.match(cell.to_s)
        next unless match

        captured = match.captures.find { |value| value && !value.strip.empty? }
        return captured.strip if captured
        return fixed.to_s.strip unless fixed.to_s.strip.empty?
      end
      nil
    end

    def extract_from_cells(cells, regexp)
      value_from_cells(cells, regexp, "")
    end

    def capturing?(regexp)
      return true unless regexp.names.empty?

      unescaped = regexp.source.gsub(/\\./, "")
      unescaped.match?(/\([^?]/) || unescaped.match?(/\(\?</)
    end

    def validate_matches!(client, rows)
      Array(rows).each do |row|
        if row.security.to_s != "" && find_security(client, row.security).nil?
          raise ArgumentError, "security not found: #{row.security}"
        end
        if row.offset_account.to_s != "" && find_vehicle(client, row.offset_account).nil?
          raise ArgumentError, "offset account not found: #{row.offset_account}"
        end
        next if row.security.to_s.empty? || row.offset_account.to_s.empty?

        vehicle = find_vehicle(client, row.offset_account)
        unless vehicle&.kind == :securities
          raise ArgumentError, "buy/sell offset must be a securities account: #{row.offset_account}"
        end
      end
    end

    SHARE_DIVISOR = 100_000_000
    SHARE_MATCH_DAYS = 7
    CASH_MATCH_DAYS = 1
    ExistingTx = Struct.new(:id, :date, :cents, :security, :shares, keyword_init: true)

    def portfolio_type(row, account: nil, client: nil)
      security = row.security.to_s != ""
      offset = row.offset_account.to_s != ""
      inflow = row.type.to_s != "REMOVAL"

      if security && offset
        inflow ? :SALE : :PURCHASE
      elsif security
        :DEPOSIT
      elsif offset
        :CASH_TRANSFER
      else
        row.type
      end
    end

    def assign_types!(rows, account, client)
      Array(rows).each do |row|
        row.proto_type = portfolio_type(row, account: account, client: client)
      end
    end

    def effective_type(row, account: nil, client: nil)
      row.proto_type || portfolio_type(row, account: account, client: client)
    end

    def preview_type(row, account: nil, client: nil)
      type = effective_type(row, account: account, client: client).to_s
      return type unless type == "CASH_TRANSFER"

      row.type.to_s == "REMOVAL" ? "TRANSFER_OUT" : "TRANSFER_IN"
    end

    def extract_shares(row)
      text = ([row.description] + FinecoXls.row_cells(row)).compact.join(" ")
      match = text.match(/Qta\/Val\.nom\.\s*([\d.,]+)/i)
      return 0 unless match

      (Float(italian_number(match[1])) * SHARE_DIVISOR).round
    rescue ArgumentError
      0
    end

    def italian_number(value)
      text = value.to_s.strip.gsub(/\s/, "")
      if text.include?(",") && text.include?(".")
        text.delete(".").tr(",", ".")
      elsif text.include?(",")
        text.tr(",", ".")
      else
        text
      end
    end

    def identity_for(row, account, client: nil)
      type = effective_type(row, account: account, client: client)
      security = %w[PURCHASE SALE].include?(type.to_s) ? row.security.to_s : ""
      TransactionIdentity.id(
        account.name,
        row.date,
        TransactionSync.signed_cents(type, row.amount_cents),
        row.description,
        row.offset_account.to_s,
        security
      )
    end

    def portfolio_identities(client, account)
      portfolio_existing(client, account).map(&:id)
    end

    def portfolio_existing(client, account)
      names = TransactionSync.uuid_names(client)
      secs = TransactionSync.security_names(client)
      client.transactions.filter_map do |tx|
        rec = TransactionSync.from_proto(tx, account, names: names, security_names: secs)
        next unless rec

        security = ""
        if tx.respond_to?(:has_security?) && tx.has_security?
          security = secs[tx.security].to_s.strip
        end
        ExistingTx.new(
          id: rec.id,
          date: rec.date,
          cents: amount_in_account_cents(tx, account),
          security: security,
          shares: tx.shares.to_i
        )
      end
    end

    def partition_existing(rows, client, account)
      remaining = portfolio_existing(client, account)
      existing = []
      missing = []
      Array(rows).each do |row|
        index = take_existing_index(remaining, row, account, client: client)
        if index
          remaining.delete_at(index)
          existing << row
        else
          missing << row
        end
      end
      [existing, missing]
    end

    def take_existing_index(remaining, row, account, client:)
      id = identity_for(row, account, client: client)
      index = remaining.index { |slot| slot.id == id }
      return index if index

      shares = extract_shares(row)
      security = row.security.to_s.strip
      if security != "" && shares.positive?
        index = remaining.index do |slot|
          slot.shares == shares &&
            !slot.security.empty? &&
            slot.security.casecmp?(security) &&
            (slot.date - row.date).abs <= SHARE_MATCH_DAYS
        end
        return index if index
      end

      remaining.index { |slot| (slot.date - row.date).abs <= CASH_MATCH_DAYS && slot.cents == row.amount_cents.abs }
    end

    def import_source(at: Time.now.utc)
      "ppapi import #{at.utc.strftime("%Y%m%dT%H%M%S")}"
    end

    def build_transaction(row, account, client: nil, source: nil)
      now = Time.now.utc
      date = Time.utc(row.date.year, row.date.month, row.date.day)
      type = effective_type(row, account: account, client: client)
      tx = Proto::PTransaction.new(
        uuid: SecureRandom.uuid,
        type: type,
        account: account.uuid,
        date: Google::Protobuf::Timestamp.new(seconds: date.to_i),
        currencyCode: account.currencyCode,
        amount: row.amount_cents,
        shares: %w[PURCHASE SALE].include?(type.to_s) ? extract_shares(row) : 0,
        note: row.description,
        updatedAt: Google::Protobuf::Timestamp.new(seconds: now.to_i, nanos: now.nsec),
        source: source || import_source(at: now)
      )
      assign_counterparts!(tx, row, account, client)
      tx
    end

    def assign_counterparts!(tx, row, account, client)
      type = tx.type.to_s
      if %w[PURCHASE SALE].include?(type)
        assign_buy_sell!(tx, row, account, client)
        return
      end
      return if row.offset_account.to_s.empty?
      raise ArgumentError, "client required to resolve offset account" if client.nil?

      if type == "CASH_TRANSFER"
        assign_cash_transfer!(tx, row, account, client)
      else
        assign_offset!(tx, row.offset_account, client)
      end
    end

    def assign_cash_transfer!(tx, row, account, client)
      other = find_account(client, row.offset_account)
      raise ArgumentError, "offset account not found: #{row.offset_account}" unless other

      inbound = row.type.to_s != "REMOVAL"
      source = inbound ? other : account
      dest = inbound ? account : other
      tx.account = source.uuid
      tx.otherAccount = dest.uuid
      tx.currencyCode = source.currencyCode
      stamp_cross_entry!(tx)

      if source.currencyCode.to_s == dest.currencyCode.to_s
        tx.amount = row.amount_cents
        return
      end

      if inbound
        dest_cents = row.amount_cents
        source_cents = convert_cents(client, dest, source, dest_cents, row.date)
        tx.amount = source_cents
        append_gross_value!(tx, source_cents, source.currencyCode, dest_cents, dest.currencyCode)
      else
        source_cents = row.amount_cents
        dest_cents = convert_cents(client, source, dest, source_cents, row.date)
        tx.amount = source_cents
        append_gross_value!(tx, source_cents, source.currencyCode, dest_cents, dest.currencyCode)
      end
    end

    def append_gross_value!(tx, amount_cents, currency, fx_cents, fx_currency)
      tx.units << Proto::PTransactionUnit.new(
        type: :GROSS_VALUE,
        amount: amount_cents,
        currencyCode: currency,
        fxAmount: fx_cents,
        fxCurrencyCode: fx_currency,
        fxRateToBase: encode_decimal(amount_cents.to_f / fx_cents)
      )
    end

    def encode_decimal(rate)
      scale = 10
      unscaled = (Float(rate) * (10**scale)).round
      Proto::PDecimal.new(
        scale: scale,
        precision: unscaled.abs.to_s.length,
        value: biginteger_bytes(unscaled)
      )
    end

    def biginteger_bytes(value)
      int = Integer(value)
      raise ArgumentError, "FX rate must be positive" unless int.positive?

      hex = int.to_s(16)
      hex = "0#{hex}" if hex.length.odd?
      bytes = [hex].pack("H*")
      bytes.getbyte(0) >= 0x80 ? "\x00".b + bytes : bytes
    end

    def convert_cents(client, from_account, to_account, cents, date)
      return cents if from_account.currencyCode.to_s == to_account.currencyCode.to_s

      rate = fx_rate(client, from_account, to_account, date)
      (Integer(cents) * rate).round
    end

    def fx_rate(client, from_account, to_account, date)
      from = from_account.currencyCode.to_s
      to = to_account.currencyCode.to_s
      pair = [from_account.uuid, to_account.uuid]
      candidates = client.transactions.select do |tx|
        next false unless tx.type.to_s == "CASH_TRANSFER"
        next false unless tx.has_account? && tx.has_otherAccount?
        next false unless pair.include?(tx.account) && pair.include?(tx.otherAccount)

        unit = gross_fx_unit(tx)
        unit && unit.amount.positive? && unit.fxAmount.positive?
      end
      if candidates.empty?
        raise ArgumentError,
              "no FX rate between #{from_account.name} (#{from}) and #{to_account.name} (#{to})"
      end

      best = candidates.min_by do |tx|
        tx_date = tx.has_date? ? Time.at(tx.date.seconds).utc.to_date : Date.new(1970, 1, 1)
        (tx_date - date).abs
      end
      rate_from_unit(gross_fx_unit(best), from, to)
    end

    def gross_fx_unit(tx)
      tx.units.find do |unit|
        unit.type.to_s == "GROSS_VALUE" && unit.has_fxAmount? && unit.has_fxCurrencyCode?
      end
    end

    def rate_from_unit(unit, from_code, to_code)
      if unit.currencyCode.to_s == from_code && unit.fxCurrencyCode.to_s == to_code
        unit.fxAmount.to_f / unit.amount
      elsif unit.currencyCode.to_s == to_code && unit.fxCurrencyCode.to_s == from_code
        unit.amount.to_f / unit.fxAmount
      else
        raise ArgumentError,
              "FX unit #{unit.currencyCode}/#{unit.fxCurrencyCode} does not match #{from_code}/#{to_code}"
      end
    end

    def amount_in_account_cents(tx, account)
      code = account.currencyCode.to_s
      return tx.amount if tx.currencyCode.to_s == code

      unit = tx.units.find do |item|
        item.type.to_s == "GROSS_VALUE" &&
          item.has_fxCurrencyCode? && item.fxCurrencyCode.to_s == code &&
          item.has_fxAmount?
      end
      unit ? unit.fxAmount : tx.amount.abs
    end

    def assign_buy_sell!(tx, row, account, client)
      raise ArgumentError, "client required to resolve buy/sell" if client.nil?
      raise ArgumentError, "buy/sell needs an offset securities account" if row.offset_account.to_s.empty?

      vehicle = find_vehicle(client, row.offset_account)
      raise ArgumentError, "offset account not found: #{row.offset_account}" unless vehicle
      unless vehicle.kind == :securities
        raise ArgumentError, "buy/sell offset must be a securities account: #{row.offset_account}"
      end

      security = find_security(client, row.security)
      raise ArgumentError, "security not found: #{row.security}" unless security

      tx.account = account.uuid
      tx.portfolio = vehicle.uuid
      tx.security = security.uuid
      stamp_cross_entry!(tx)
    end

    def stamp_cross_entry!(tx)
      now = Time.now.utc
      tx.otherUuid = SecureRandom.uuid if tx.otherUuid.to_s.empty?
      return if tx.has_otherUpdatedAt?

      tx.otherUpdatedAt = Google::Protobuf::Timestamp.new(seconds: now.to_i, nanos: now.nsec)
    end

    def repair_cross_entries!(client)
      stamped = 0
      client.transactions.each do |tx|
        next unless CROSS_ENTRY_TYPES.include?(tx.type.to_s)

        missing = tx.otherUuid.to_s.empty? || !tx.has_otherUpdatedAt?
        stamp_cross_entry!(tx)
        stamped += 1 if missing
      end
      stamped
    end

    def assign_offset!(tx, name, client)
      vehicle = find_vehicle(client, name)
      raise ArgumentError, "offset account not found: #{name}" unless vehicle

      if vehicle.kind == :securities
        tx.portfolio = vehicle.uuid
      else
        tx.otherAccount = vehicle.uuid
      end
    end

    def append!(client, account, rows, at: Time.now.utc)
      repair_cross_entries!(client)
      source = import_source(at: at)
      rows.each do |row|
        client.transactions << build_transaction(row, account, client: client, source: source)
      end
      rows.size
    end
  end
end
