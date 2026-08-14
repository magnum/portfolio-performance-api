# frozen_string_literal: true

require "json"
require "sinatra/base"

module PortfolioPerformanceApi
  class App < Sinatra::Base
    configure do
      set :show_exceptions, false
      set :raise_errors, false
      set :dump_errors, ENV["RACK_ENV"] != "test"
      set :logging, ENV["RACK_ENV"] != "test"
      disable :static
    end

    configure :development do
      require "sinatra/reloader"
      register Sinatra::Reloader
      Dir[File.expand_path("**/*.rb", __dir__)].each do |path|
        also_reload path
      end
    end

    error Unauthorized do
      error_json 401, "unauthorized"
    end

    error NotConfigured do
      error_json 500, "not_configured"
    end

    error IncorrectPassword, NotAPortfolioFile do
      error_json 422, "portfolio_error"
    end

    error DriveError do
      error_json 502, "drive_error"
    end

    error do
      error_json 500, "internal_error"
    end

    get "/health" do
      json(status: "ok", version: VERSION)
    end

    get "/accounts.csv" do
      payload = accounts_payload
      lang = AccountsCsv.normalize_locale(params["locale"])
      content_type "text/csv", charset: "utf-8"
      headers["Content-Language"] = lang
      headers["Cache-Control"] = "private, no-store"
      headers["Content-Disposition"] = %(inline; filename="accounts-#{lang}.csv")
      AccountsCsv.generate(payload, locale: lang)
    end

    get "/accounts.json" do
      json(accounts_payload)
    end

    get "/accounts" do
      json(accounts_payload)
    end

    get "/" do
      json(accounts_payload)
    end

    helpers do
      def accounts_payload
        Auth.require!(env)
        snapshot.accounts(nocache: nocache?)
      end

      def snapshot
        self.class.snapshot
      end

      def nocache?
        params.key?("nocache")
      end

      def json(object = nil, **fields)
        payload = object.nil? ? fields : object
        content_type "application/json"
        JSON.generate(payload)
      end

      def error_json(status_code, name)
        status status_code
        json(error: name, message: env["sinatra.error"].message)
      end
    end

    def self.snapshot
      PortfolioPerformanceApi.snapshot
    end

    def self.snapshot=(value)
      PortfolioPerformanceApi.snapshot = value
    end
  end
end
