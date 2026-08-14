# frozen_string_literal: true

require "dotenv/load"
require_relative "lib/portfolio_performance_api"

run PortfolioPerformanceApi::App.freeze.app
