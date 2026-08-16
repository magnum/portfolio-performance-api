# frozen_string_literal: true

require "digest"

module PortfolioPerformanceApi
  class TransactionIdentity
    SEPARATOR = "\u001f"

    attr_reader :account_name, :date, :signed_cents, :description, :destination, :security

    def initialize(account_name:, date:, signed_cents:, description:, destination: "", security: "")
      @account_name = account_name.to_s.strip
      @date = date
      @signed_cents = Integer(signed_cents)
      @description = self.class.normalize_description(description)
      @destination = destination.to_s.strip
      @security = security.to_s.strip
    end

    def id
      Digest::SHA256.hexdigest(
        [
          @account_name,
          @date.strftime("%Y-%m-%d"),
          @signed_cents.to_s,
          @description,
          @destination,
          @security
        ].join(SEPARATOR)
      )
    end
    alias to_s id

    def self.id(account_name, date, signed_cents, description, destination = "", security = "")
      new(
        account_name: account_name,
        date: date,
        signed_cents: signed_cents,
        description: description,
        destination: destination,
        security: security
      ).id
    end

    def self.normalize_description(value)
      value.to_s.strip.gsub(/\s+/, " ")
    end
  end
end
