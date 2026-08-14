# frozen_string_literal: true

require "nokogiri"

module PortfolioPerformanceApi
  class Parser
    KIND_DEPOSIT = "deposit"
    KIND_SECURITIES = "securities"

    Account = Struct.new(
      :uuid, :name, :currency, :retired, :note, :kind, :reference_account_uuid,
      keyword_init: true
    )
    Security = Struct.new(:uuid, :name, :currency, :quote, keyword_init: true)
    Transaction = Struct.new(
      :type, :account_uuid, :other_account_uuid, :portfolio_uuid, :other_portfolio_uuid,
      :amount_cents, :currency, :shares, :security_uuid, :units,
      keyword_init: true
    )
    Unit = Struct.new(:type, :amount_cents, :currency, :fx_amount_cents, :fx_currency, keyword_init: true)
    Client = Struct.new(
      :base_currency, :version, :accounts, :portfolios, :securities, :transactions,
      keyword_init: true
    )

    def self.parse(result)
      case result.format
      when :xml then parse_xml(result.bytes, version: result.version)
      when :protobuf then parse_protobuf(result.bytes, version: result.version)
      else
        raise Error, "unsupported portfolio format #{result.format}"
      end
    end

    def self.parse_xml(bytes, version: nil)
      doc = Nokogiri::XML(bytes) { |config| config.nonet.noblanks }
      root = doc.at_xpath("/client") || doc.root
      raise NotAPortfolioFile, "XML is not a Portfolio Performance client" unless root

      accounts = root.xpath("./accounts/account").map { |node| xml_account(node) }
      portfolios = root.xpath("./portfolios/portfolio").map { |node| xml_portfolio(node, accounts) }
      securities = root.xpath("./securities/security").map { |node| xml_security(node) }

      transactions = []
      root.xpath("./accounts/account").each do |account_node|
        uuid = text_at(account_node, "uuid")
        account_node.xpath("./transactions/account-transaction").each do |tx_node|
          next if tx_node["reference"]

          transactions << xml_transaction(tx_node, account_uuid: uuid)
        end
      end
      root.xpath("./portfolios/portfolio").each do |portfolio_node|
        uuid = text_at(portfolio_node, "uuid")
        portfolio_node.xpath("./transactions/portfolio-transaction").each do |tx_node|
          next if tx_node["reference"]

          transactions << xml_transaction(tx_node, portfolio_uuid: uuid)
        end
      end

      Client.new(
        base_currency: text_at(root, "baseCurrency") || "EUR",
        version: version || integer_at(root, "version"),
        accounts: accounts,
        portfolios: portfolios,
        securities: securities,
        transactions: transactions
      )
    end

    def self.parse_protobuf(bytes, version: nil)
      client = Proto::PClient.decode(bytes)
      accounts = client.accounts.map do |account|
        Account.new(
          uuid: account.uuid,
          name: account.name,
          currency: account.currencyCode,
          retired: account.isRetired,
          note: account.has_note? ? account.note : nil,
          kind: KIND_DEPOSIT
        )
      end
      accounts_by_uuid = accounts.to_h { |account| [account.uuid, account] }

      portfolios = client.portfolios.map do |portfolio|
        reference = portfolio.has_referenceAccount? ? portfolio.referenceAccount : nil
        Account.new(
          uuid: portfolio.uuid,
          name: portfolio.name,
          currency: accounts_by_uuid[reference]&.currency,
          retired: portfolio.isRetired,
          note: portfolio.has_note? ? portfolio.note : nil,
          kind: KIND_SECURITIES,
          reference_account_uuid: reference
        )
      end

      securities = client.securities.map do |security|
        Security.new(
          uuid: security.uuid,
          name: security.name,
          currency: security.has_currencyCode? ? security.currencyCode : nil,
          quote: protobuf_quote(security)
        )
      end

      transactions = client.transactions.map do |tx|
        Transaction.new(
          type: normalize_type(tx.type.to_s),
          account_uuid: tx.has_account? ? tx.account : nil,
          other_account_uuid: tx.has_otherAccount? ? tx.otherAccount : nil,
          portfolio_uuid: tx.has_portfolio? ? tx.portfolio : nil,
          other_portfolio_uuid: tx.has_otherPortfolio? ? tx.otherPortfolio : nil,
          amount_cents: tx.amount,
          currency: tx.currencyCode,
          shares: tx.has_shares? ? tx.shares : 0,
          security_uuid: tx.has_security? ? tx.security : nil,
          units: tx.units.map do |unit|
            Unit.new(
              type: unit.type.to_s,
              amount_cents: unit.amount,
              currency: unit.currencyCode,
              fx_amount_cents: unit.has_fxAmount? ? unit.fxAmount : nil,
              fx_currency: unit.has_fxCurrencyCode? ? unit.fxCurrencyCode : nil
            )
          end
        )
      end

      Client.new(
        base_currency: client.baseCurrency.empty? ? "EUR" : client.baseCurrency,
        version: version || client.version,
        accounts: accounts,
        portfolios: portfolios,
        securities: securities,
        transactions: transactions
      )
    end

    def self.xml_account(node)
      Account.new(
        uuid: text_at(node, "uuid"),
        name: text_at(node, "name"),
        currency: text_at(node, "currencyCode") || "EUR",
        retired: text_at(node, "isRetired") == "true",
        note: text_at(node, "note"),
        kind: KIND_DEPOSIT
      )
    end

    def self.xml_portfolio(node, accounts)
      reference = referenced_uuid(node.at_xpath("./referenceAccount"))
      Account.new(
        uuid: text_at(node, "uuid"),
        name: text_at(node, "name"),
        currency: accounts.find { |account| account.uuid == reference }&.currency,
        retired: text_at(node, "isRetired") == "true",
        note: text_at(node, "note"),
        kind: KIND_SECURITIES,
        reference_account_uuid: reference
      )
    end

    def self.xml_security(node)
      latest = node.at_xpath("./latest")
      quote = if latest && latest["v"]
        Integer(latest["v"])
      else
        price = node.xpath("./prices/price").max_by { |item| item["t"].to_s }
        price && price["v"] ? Integer(price["v"]) : 0
      end

      Security.new(
        uuid: text_at(node, "uuid"),
        name: text_at(node, "name"),
        currency: text_at(node, "currencyCode"),
        quote: quote
      )
    end

    def self.xml_transaction(node, account_uuid: nil, portfolio_uuid: nil)
      type = normalize_type(text_at(node, "type"), portfolio: !portfolio_uuid.nil?)
      Transaction.new(
        type: type,
        account_uuid: account_uuid,
        other_account_uuid: referenced_uuid(node.at_xpath("./otherAccount")),
        portfolio_uuid: portfolio_uuid,
        other_portfolio_uuid: referenced_uuid(node.at_xpath("./otherPortfolio")),
        amount_cents: integer_at(node, "amount"),
        currency: text_at(node, "currencyCode"),
        shares: integer_at(node, "shares"),
        security_uuid: referenced_uuid(node.at_xpath("./security")),
        units: []
      )
    end

    def self.protobuf_quote(security)
      return security.latest.close if security.has_latest?

      prices = security.prices
      return 0 if prices.empty?

      prices.max_by(&:date).close
    end

    def self.referenced_uuid(node)
      target = resolve_reference(node)
      return if target.nil?

      text_at(target, "uuid") || target["uuid"]
    end

    def self.resolve_reference(node)
      return if node.nil?

      ref = node["reference"]
      return node unless ref

      node.at_xpath(ref)
    end

    def self.normalize_type(type, portfolio: false)
      case type.to_s.upcase
      when "BUY" then "PURCHASE"
      when "SELL" then "SALE"
      when "DIVIDENDS" then "DIVIDEND"
      when "TAXES" then "TAX"
      when "FEES" then "FEE"
      when "FEES_REFUND" then "FEE_REFUND"
      when "DELIVERY_INBOUND" then "INBOUND_DELIVERY"
      when "DELIVERY_OUTBOUND" then "OUTBOUND_DELIVERY"
      when "TRANSFER_OUT" then (portfolio ? "SECURITY_TRANSFER" : "CASH_TRANSFER")
      when "TRANSFER_IN" then "TRANSFER_IN"
      else type.to_s.upcase
      end
    end

    def self.text_at(node, name)
      child = node.at_xpath("./#{name}")
      return if child.nil?

      value = child.text
      value.empty? ? nil : value
    end

    def self.integer_at(node, name)
      Integer(text_at(node, name) || 0)
    end
    private_class_method :xml_account, :xml_portfolio, :xml_security, :xml_transaction,
                         :protobuf_quote, :referenced_uuid, :resolve_reference,
                         :normalize_type, :text_at, :integer_at
  end
end
