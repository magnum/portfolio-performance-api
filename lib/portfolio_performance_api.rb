# frozen_string_literal: true

require "roda"
require "json"
require "time"
require "nokogiri"

require_relative "portfolio_performance_api/proto/client_pb"
require_relative "portfolio_performance_api/config"
require_relative "portfolio_performance_api/errors"
require_relative "portfolio_performance_api/decryptor"
require_relative "portfolio_performance_api/file_reader"
require_relative "portfolio_performance_api/parser"
require_relative "portfolio_performance_api/balances"
require_relative "portfolio_performance_api/drive_client"
require_relative "portfolio_performance_api/portfolio_source"
require_relative "portfolio_performance_api/cache"
require_relative "portfolio_performance_api/snapshot"
require_relative "portfolio_performance_api/auth"
require_relative "portfolio_performance_api/app"

module PortfolioPerformanceApi
  VERSION = "0.1.0"

  # Held here so Roda can freeze App without blocking lazy Snapshot init.
  @snapshot_mutex = Mutex.new

  class << self
    def snapshot
      return @snapshot if @snapshot

      @snapshot_mutex.synchronize do
        @snapshot ||= Snapshot.new
      end
    end

    def snapshot=(value)
      @snapshot_mutex.synchronize do
        @snapshot = value
      end
    end
  end
end
