# frozen_string_literal: true

require "nokogiri"

module PortfolioPerformanceApi
  class Parser
    Account = Struct.new(:uuid, :name, :currency, :retired, :note, keyword_init: true)
    Transaction = Struct.new(:type, :account_uuid, :other_account_uuid, :amount_cents, :currency, :units, keyword_init: true)
    Unit = Struct.new(:type, :amount_cents, :currency, :fx_amount_cents, :fx_currency, keyword_init: true)
    Client = Struct.new(:base_currency, :version, :accounts, :transactions, keyword_init: true)

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
      transactions = []
      root.xpath("./accounts/account").each do |account_node|
        uuid = text_at(account_node, "uuid")
        account_node.xpath("./transactions/account-transaction").each do |tx_node|
          next if tx_node["reference"]

          transactions << Transaction.new(
            type: normalize_type(text_at(tx_node, "type")),
            account_uuid: uuid,
            other_account_uuid: nil,
            amount_cents: integer_at(tx_node, "amount"),
            currency: text_at(tx_node, "currencyCode"),
            units: []
          )
        end
      end

      Client.new(
        base_currency: text_at(root, "baseCurrency") || "EUR",
        version: version || integer_at(root, "version"),
        accounts: accounts,
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
          note: account.has_note? ? account.note : nil
        )
      end

      transactions = client.transactions.map do |tx|
        Transaction.new(
          type: normalize_type(tx.type.to_s),
          account_uuid: tx.has_account? ? tx.account : nil,
          other_account_uuid: tx.has_otherAccount? ? tx.otherAccount : nil,
          amount_cents: tx.amount,
          currency: tx.currencyCode,
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
        transactions: transactions
      )
    end

    def self.xml_account(node)
      Account.new(
        uuid: text_at(node, "uuid"),
        name: text_at(node, "name"),
        currency: text_at(node, "currencyCode") || "EUR",
        retired: text_at(node, "isRetired") == "true",
        note: text_at(node, "note")
      )
    end

    def self.normalize_type(type)
      case type.to_s.upcase
      when "BUY" then "PURCHASE"
      when "SELL" then "SALE"
      when "DIVIDENDS" then "DIVIDEND"
      when "TAXES" then "TAX"
      when "FEES" then "FEE"
      when "FEES_REFUND" then "FEE_REFUND"
      when "TRANSFER_OUT" then "CASH_TRANSFER"
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
    private_class_method :xml_account, :normalize_type, :text_at, :integer_at
  end
end
