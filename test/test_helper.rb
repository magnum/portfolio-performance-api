# frozen_string_literal: true

require "minitest/autorun"
require "rack/test"
require "json"
require "stringio"
require "zip"
require "time"

ENV["RACK_ENV"] ||= "test"
ENV["API_KEY"] ||= "test-key"
ENV["PORTFOLIO_PASSWORD"] ||= "secret"
ENV["CACHE_TTL_MINUTES"] ||= "15"
ENV["INCLUDE_RETIRED"] ||= "true"
ENV.delete("GOOGLE_DRIVE_FILE_ID")
ENV.delete("GOOGLE_SERVICE_ACCOUNT_JSON")
ENV.delete("GOOGLE_APPLICATION_CREDENTIALS")
ENV.delete("PORTFOLIO_FILE")

require_relative "../lib/portfolio_performance_api"

module PortfolioFixtures
  XML = <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <client>
      <version>70</version>
      <baseCurrency>EUR</baseCurrency>
      <accounts>
        <account>
          <uuid>acc-cash</uuid>
          <name>Conto corrente</name>
          <currencyCode>EUR</currencyCode>
          <isRetired>false</isRetired>
          <transactions>
            <account-transaction>
              <uuid>tx-1</uuid>
              <currencyCode>EUR</currencyCode>
              <amount>100000</amount>
              <type>DEPOSIT</type>
            </account-transaction>
            <account-transaction>
              <uuid>tx-2</uuid>
              <currencyCode>EUR</currencyCode>
              <amount>2500</amount>
              <type>FEES</type>
            </account-transaction>
            <account-transaction>
              <uuid>tx-3</uuid>
              <currencyCode>EUR</currencyCode>
              <amount>10000</amount>
              <type>TRANSFER_OUT</type>
            </account-transaction>
          </transactions>
        </account>
        <account>
          <uuid>acc-savings</uuid>
          <name>Risparmio</name>
          <currencyCode>EUR</currencyCode>
          <isRetired>false</isRetired>
          <transactions>
            <account-transaction>
              <uuid>tx-4</uuid>
              <currencyCode>EUR</currencyCode>
              <amount>10000</amount>
              <type>TRANSFER_IN</type>
            </account-transaction>
            <account-transaction>
              <uuid>tx-5</uuid>
              <currencyCode>EUR</currencyCode>
              <amount>1500</amount>
              <type>INTEREST</type>
            </account-transaction>
          </transactions>
        </account>
        <account>
          <uuid>acc-old</uuid>
          <name>Chiuso</name>
          <currencyCode>EUR</currencyCode>
          <isRetired>true</isRetired>
          <transactions>
            <account-transaction>
              <uuid>tx-6</uuid>
              <currencyCode>EUR</currencyCode>
              <amount>1</amount>
              <type>DEPOSIT</type>
            </account-transaction>
          </transactions>
        </account>
      </accounts>
      <securities>
        <security>
          <uuid>sec-etf</uuid>
          <name>VWCE</name>
          <currencyCode>EUR</currencyCode>
          <latest t="2024-01-15" v="10000000000"/>
        </security>
      </securities>
      <portfolios>
        <portfolio>
          <uuid>port-titoli</uuid>
          <name>Deposito titoli</name>
          <isRetired>false</isRetired>
          <referenceAccount>
            <uuid>acc-cash</uuid>
          </referenceAccount>
          <transactions>
            <portfolio-transaction>
              <uuid>tx-buy</uuid>
              <currencyCode>EUR</currencyCode>
              <amount>100000</amount>
              <shares>100000000</shares>
              <security>
                <uuid>sec-etf</uuid>
              </security>
              <type>BUY</type>
            </portfolio-transaction>
          </transactions>
        </portfolio>
      </portfolios>
    </client>
  XML

  module_function

  def zip_xml(xml = XML)
    Zip::OutputStream.write_buffer do |zio|
      zio.put_next_entry("data.xml")
      zio.write xml
    end.string
  end

  def encrypted_xml(password: "secret", xml: XML)
    PortfolioPerformanceApi::Decryptor.encrypt(
      zip_xml(xml),
      password,
      aes256: true,
      content_type: 1,
      version: 70
    )
  end

  def protobuf_client
    proto = PortfolioPerformanceApi::Proto
    proto::PClient.new(
      version: 70,
      baseCurrency: "EUR",
      accounts: [
        proto::PAccount.new(uuid: "acc-cash", name: "Conto corrente", currencyCode: "EUR", isRetired: false),
        proto::PAccount.new(uuid: "acc-savings", name: "Risparmio", currencyCode: "EUR", isRetired: false)
      ],
      portfolios: [
        proto::PPortfolio.new(uuid: "port-titoli", name: "Deposito titoli", isRetired: false, referenceAccount: "acc-cash")
      ],
      securities: [
        proto::PSecurity.new(
          uuid: "sec-etf",
          name: "VWCE",
          currencyCode: "EUR",
          latest: proto::PFullHistoricalPrice.new(date: 19_737, close: 10_000_000_000)
        )
      ],
      transactions: [
        proto::PTransaction.new(uuid: "tx-1", type: :DEPOSIT, account: "acc-cash", currencyCode: "EUR", amount: 100_000),
        proto::PTransaction.new(uuid: "tx-2", type: :FEE, account: "acc-cash", currencyCode: "EUR", amount: 2_500),
        proto::PTransaction.new(
          uuid: "tx-3",
          type: :CASH_TRANSFER,
          account: "acc-cash",
          otherAccount: "acc-savings",
          currencyCode: "EUR",
          amount: 10_000
        ),
        proto::PTransaction.new(uuid: "tx-5", type: :INTEREST, account: "acc-savings", currencyCode: "EUR", amount: 1_500),
        proto::PTransaction.new(
          uuid: "tx-buy",
          type: :PURCHASE,
          portfolio: "port-titoli",
          currencyCode: "EUR",
          amount: 100_000,
          shares: 100_000_000,
          security: "sec-etf"
        )
      ]
    )
  end

  def zip_protobuf(client = protobuf_client)
    Zip::OutputStream.write_buffer do |zio|
      zio.put_next_entry("data.portfolio")
      zio.write("PPPBV1" + client.to_proto)
    end.string
  end

  def encrypted_protobuf(password: "secret")
    PortfolioPerformanceApi::Decryptor.encrypt(
      zip_protobuf,
      password,
      aes256: true,
      content_type: 2,
      version: 70
    )
  end
end
