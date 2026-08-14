# frozen_string_literal: true

module PortfolioPerformanceApi
  class Balances
    # Signs match Account#getCurrentAmount in Portfolio Performance.
    # XML stores TRANSFER_IN on the destination account; protobuf stores a
    # single CASH_TRANSFER on the source (otherAccount = destination).
    CASH_SIGN = {
      "DEPOSIT" => 1,
      "REMOVAL" => -1,
      "DIVIDEND" => 1,
      "INTEREST" => 1,
      "INTEREST_CHARGE" => -1,
      "TAX_REFUND" => 1,
      "TAX" => -1,
      "FEE_REFUND" => 1,
      "FEE" => -1,
      "SALE" => 1,
      "PURCHASE" => -1,
      "TRANSFER_IN" => 1
    }.freeze

    def self.compute(client, include_retired: true)
      accounts = client.accounts
      accounts = accounts.reject(&:retired) unless include_retired

      rows = accounts.map do |account|
        cents = balance_cents(account, client.transactions)
        {
          uuid: account.uuid,
          name: account.name,
          currency: account.currency,
          retired: account.retired,
          balance: cents / 100.0,
          balance_cents: cents
        }
      end

      totals = rows.group_by { |row| row[:currency] }.map do |currency, group|
        cents = group.sum { |row| row[:balance_cents] }
        { currency: currency, balance: cents / 100.0, balance_cents: cents }
      end

      {
        base_currency: client.base_currency,
        version: client.version,
        accounts: rows,
        totals: totals
      }
    end

    def self.balance_cents(account, transactions)
      transactions.sum { |tx| signed_amount(account, tx) }
    end

    def self.signed_amount(account, tx)
      type = tx.type
      if type == "CASH_TRANSFER"
        return cash_transfer_amount(account, tx)
      end

      return 0 unless tx.account_uuid == account.uuid

      sign = CASH_SIGN[type]
      sign ? sign * tx.amount_cents : 0
    end

    def self.cash_transfer_amount(account, tx)
      if tx.account_uuid == account.uuid
        -tx.amount_cents
      elsif tx.other_account_uuid == account.uuid
        target_amount(account, tx)
      else
        0
      end
    end

    def self.target_amount(account, tx)
      if tx.currency == account.currency
        return tx.amount_cents
      end

      fx = Array(tx.units).find do |unit|
        unit.type.to_s == "GROSS_VALUE" &&
          unit.fx_currency == account.currency &&
          !unit.fx_amount_cents.nil?
      end
      fx ? fx.fx_amount_cents : tx.amount_cents
    end
    private_class_method :balance_cents, :signed_amount, :cash_transfer_amount, :target_amount
  end
end
