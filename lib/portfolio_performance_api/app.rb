# frozen_string_literal: true

module PortfolioPerformanceApi
  class App < Roda
    plugin :json
    plugin :halt
    plugin :json_parser
    plugin :common_logger, $stderr unless ENV["RACK_ENV"] == "test"

    plugin :error_handler do |error|
      case error
      when Unauthorized
        response.status = 401
        { error: "unauthorized", message: error.message }
      when NotConfigured
        response.status = 500
        { error: "not_configured", message: error.message }
      when IncorrectPassword, NotAPortfolioFile
        response.status = 422
        { error: "portfolio_error", message: error.message }
      when DriveError
        response.status = 502
        { error: "drive_error", message: error.message }
      else
        response.status = 500
        { error: "internal_error", message: error.message }
      end
    end

    route do |r|
      r.get "health" do
        { status: "ok", version: VERSION }
      end

      r.get "accounts" do
        accounts_payload(r)
      end

      r.root do
        accounts_payload(r)
      end
    end

    def accounts_payload(request)
      Auth.require!(env)
      snapshot.accounts(nocache: nocache?(request))
    end

    def snapshot
      self.class.snapshot
    end

    def nocache?(request)
      request.params.key?("nocache")
    end

    def self.snapshot
      PortfolioPerformanceApi.snapshot
    end

    def self.snapshot=(value)
      PortfolioPerformanceApi.snapshot = value
    end
  end
end
