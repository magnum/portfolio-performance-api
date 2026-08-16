# frozen_string_literal: true

require "securerandom"
require "time"

require_relative "transaction_identity"
require_relative "transaction_sync"
require_relative "fineco_xls"

module PortfolioPerformanceApi
  module FinecoImport
    DEFAULT_SECURITY_SPEC = "/Compravendita Titoli\\s+(.+?)\\s+Qta/"

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
      end
    end

    def identity_for(row, account)
      TransactionIdentity.id(
        account.name,
        row.date,
        TransactionSync.signed_cents(row.type, row.amount_cents),
        row.description,
        row.offset_account.to_s,
        row.security.to_s
      )
    end

    def portfolio_identities(client, account)
      names = TransactionSync.uuid_names(client)
      secs = TransactionSync.security_names(client)
      client.transactions.filter_map do |tx|
        TransactionSync.from_proto(tx, account, names: names, security_names: secs)&.id
      end
    end

    def partition_existing(rows, client, account)
      remaining = portfolio_identities(client, account)
      existing = []
      missing = []
      Array(rows).each do |row|
        index = remaining.index(identity_for(row, account))
        if index
          remaining.delete_at(index)
          existing << row
        else
          missing << row
        end
      end
      [existing, missing]
    end

    def build_transaction(row, account, client: nil)
      now = Time.now.utc
      date = Time.utc(row.date.year, row.date.month, row.date.day)
      tx = Proto::PTransaction.new(
        uuid: SecureRandom.uuid,
        type: row.type,
        account: account.uuid,
        date: Google::Protobuf::Timestamp.new(seconds: date.to_i),
        currencyCode: account.currencyCode,
        amount: row.amount_cents,
        shares: 0,
        note: row.description,
        updatedAt: Google::Protobuf::Timestamp.new(seconds: now.to_i, nanos: now.nsec)
      )
      if row.offset_account.to_s != ""
        raise ArgumentError, "client required to resolve offset account" if client.nil?

        assign_offset!(tx, row.offset_account, client)
      end
      if row.security.to_s != ""
        raise ArgumentError, "client required to resolve security" if client.nil?

        security = find_security(client, row.security)
        raise ArgumentError, "security not found: #{row.security}" unless security

        tx.security = security.uuid
      end
      tx
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

    def append!(client, account, rows)
      rows.each do |row|
        client.transactions << build_transaction(row, account, client: client)
      end
      rows.size
    end
  end
end
