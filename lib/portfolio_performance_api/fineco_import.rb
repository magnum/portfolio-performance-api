# frozen_string_literal: true

require "securerandom"
require "time"

module PortfolioPerformanceApi
  module FinecoImport
    module_function

    def find_account(client, name)
      accounts = client.accounts.select { |account| account.name == name }
      accounts = client.accounts.select { |account| account.name.casecmp?(name) } if accounts.empty?
      accounts = client.accounts.select { |account| account.uuid == name } if accounts.empty?
      accounts.first
    end

    def last_transaction_date(client, account_uuid)
      client.transactions.filter_map do |tx|
        next unless tx.has_account? && tx.account == account_uuid
        next unless tx.has_date?

        Time.at(tx.date.seconds).utc.to_date
      end.max
    end

    def newer_than(rows, last_date)
      return rows if last_date.nil?

      rows.select { |row| row.date > last_date }
    end

    def build_transaction(row, account)
      now = Time.now.utc
      date = Time.utc(row.date.year, row.date.month, row.date.day)
      Proto::PTransaction.new(
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
    end

    def append!(client, account, rows)
      rows.each do |row|
        client.transactions << build_transaction(row, account)
      end
      rows.size
    end
  end
end
