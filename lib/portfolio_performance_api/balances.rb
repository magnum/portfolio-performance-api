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

    SHARE_DIVISOR = 100_000_000
    QUOTE_DIVISOR = 100_000_000

    def self.compute(client, include_retired: true)
      deposits = Array(client.accounts)
      portfolios = Array(client.portfolios)
      unless include_retired
        deposits = deposits.reject(&:retired)
        portfolios = portfolios.reject(&:retired)
      end

      rows = deposits.map { |account| deposit_row(account, client) } +
             portfolios.map { |account| securities_row(account, client) }

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

    def self.deposit_row(account, client)
      cents = cash_balance_cents(account, client.transactions)
      {
        uuid: account.uuid,
        kind: Parser::KIND_DEPOSIT,
        name: account.name,
        currency: account.currency,
        retired: account.retired,
        balance: cents / 100.0,
        balance_cents: cents
      }
    end

    def self.securities_row(account, client)
      cents = market_value_cents(account, client)
      {
        uuid: account.uuid,
        kind: Parser::KIND_SECURITIES,
        name: account.name,
        currency: account.currency || client.base_currency,
        retired: account.retired,
        balance: cents / 100.0,
        balance_cents: cents,
        reference_account_uuid: account.reference_account_uuid
      }
    end

    def self.cash_balance_cents(account, transactions)
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

    def self.market_value_cents(portfolio, client)
      securities = Array(client.securities).to_h { |security| [security.uuid, security] }
      shares_by_security = Hash.new(0)
      Array(client.transactions).each do |tx|
        delta = share_delta(portfolio.uuid, tx)
        next if delta.zero? || tx.security_uuid.to_s.empty?

        shares_by_security[tx.security_uuid] += delta
      end

      shares_by_security.sum do |security_uuid, shares|
        next 0 if shares.zero?

        security = securities[security_uuid]
        next 0 if security.nil? || security.quote.to_i.zero?

        (shares * security.quote) / (SHARE_DIVISOR * QUOTE_DIVISOR / 100)
      end
    end

    def self.share_delta(portfolio_uuid, tx)
      case tx.type
      when "PURCHASE", "INBOUND_DELIVERY", "TRANSFER_IN"
        tx.portfolio_uuid == portfolio_uuid ? tx.shares.to_i : 0
      when "SALE", "OUTBOUND_DELIVERY"
        tx.portfolio_uuid == portfolio_uuid ? -tx.shares.to_i : 0
      when "SECURITY_TRANSFER"
        if tx.portfolio_uuid == portfolio_uuid
          -tx.shares.to_i
        elsif tx.other_portfolio_uuid == portfolio_uuid
          tx.shares.to_i
        else
          0
        end
      else
        0
      end
    end
    private_class_method :deposit_row, :securities_row, :cash_balance_cents, :signed_amount,
                         :cash_transfer_amount, :target_amount, :market_value_cents, :share_delta
  end
end
