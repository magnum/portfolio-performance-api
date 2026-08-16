#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "dotenv"

root = File.expand_path("../..", __dir__)
Dotenv.load(File.join(root, ".env"))
$LOAD_PATH.unshift(File.join(root, "lib"))

require "portfolio_performance_api/errors"
require "portfolio_performance_api/decryptor"
require "portfolio_performance_api/file_reader"
require "portfolio_performance_api/proto/client_pb"
require "portfolio_performance_api/config"
require "portfolio_performance_api/drive_client"
require "portfolio_performance_api/portfolio_store"
require "portfolio_performance_api/sheets_client"
require "portfolio_performance_api/transaction_sync"
require "portfolio_performance_api/sync_preview"

module PortfolioSyncCli
  module_function

  def main
    portfolio_id = PortfolioPerformanceApi::Config.drive_file_id
    spreadsheet_id = PortfolioPerformanceApi::Config.sync_drive_file_id
    password = PortfolioPerformanceApi::Config.portfolio_password
    abort "missing PORTFOLIO_GOOGLE_DRIVE_FILE_ID" if portfolio_id.to_s.empty?
    abort "missing SYNC_GOOGLE_DRIVE_FILE_ID" if spreadsheet_id.to_s.empty?
    abort "missing GOOGLE_SERVICE_ACCOUNT_JSON" if PortfolioPerformanceApi::Config.service_account_json.to_s.empty?

    session = PortfolioPerformanceApi::DriveClient.new(
      file_id: portfolio_id,
      scope: PortfolioPerformanceApi::DriveClient::SYNC_SCOPE
    )
    sheets = PortfolioPerformanceApi::SheetsClient.new(session: session, spreadsheet_id: spreadsheet_id)

    downloaded = session.download
    loaded = PortfolioPerformanceApi::PortfolioStore.load_bytes(
      downloaded.fetch(:bytes),
      password: password,
      path: downloaded.dig(:meta, :name)
    )
    skip_rows = PortfolioPerformanceApi::Config.sync_skip_rows
    chunk_size = PortfolioPerformanceApi::Config.sync_rows_chunk
    preview_rows = PortfolioPerformanceApi::Config.sync_preview_rows
    names = PortfolioPerformanceApi::TransactionSync.uuid_names(loaded.client)
    known_sheets = sheets.sheet_titles
    portfolio_changed = false

    unique_titles(PortfolioPerformanceApi::TransactionSync.vehicles(loaded.client)).each do |title, vehicle|
      raw_rows = known_sheets.include?(title) ? sheets.read_rows(title) : []
      sheet_plan, portfolio_plan = account_plans(
        loaded.client, vehicle, raw_rows, names, skip_rows
      )
      puts "#{vehicle.name}: spreadsheet +#{sheet_plan.create_sheet.size}/~#{sheet_plan.update_sheet.size}  " \
           "portfolio +#{portfolio_plan.create_portfolio.size}/~#{portfolio_plan.update_portfolio.size}"

      if empty_plan?(sheet_plan) && empty_plan?(portfolio_plan)
        puts "#{vehicle.name}: already in sync"
        next
      end

      choice = preview_account(vehicle.name, sheet_plan, portfolio_plan, preview_rows)
      if choice == "N"
        puts "#{vehicle.name}: skipped"
        next
      end
      if %w[S B].include?(choice)
        unless sheet_plan.create_sheet.empty? && sheet_plan.update_sheet.empty?
          unless known_sheets.include?(title)
            sheets.ensure_sheet(title, known_titles: known_sheets)
            known_sheets << title
          end
          PortfolioPerformanceApi::TransactionSync.apply_sheet(
            sheets, title, sheet_plan, skip_rows: skip_rows, chunk_size: chunk_size, raw_rows: raw_rows
          )
          puts "#{vehicle.name}: spreadsheet written"
        end
      end
      if %w[P B].include?(choice)
        records = portfolio_plan.create_portfolio + portfolio_plan.update_portfolio
        unless records.empty?
          applied = PortfolioPerformanceApi::TransactionSync.apply_portfolio!(
            loaded.client,
            vehicle,
            records
          )
          portfolio_changed ||= applied.positive?
          names = PortfolioPerformanceApi::TransactionSync.uuid_names(loaded.client)
          puts "#{vehicle.name}: portfolio updated"
        end
      end
    end

    if portfolio_changed
      session.upload(PortfolioPerformanceApi::PortfolioStore.dump(loaded))
      puts "Uploaded portfolio #{downloaded.dig(:meta, :name)}"
    else
      puts "Portfolio file unchanged"
    end
  rescue PortfolioPerformanceApi::Error, ArgumentError => error
    abort error.message
  end

  def account_plans(client, vehicle, raw_rows, names, skip_rows)
    plan = PortfolioPerformanceApi::TransactionSync.account_plan(
      client, vehicle, raw_rows, names: names, skip_rows: skip_rows
    )
    PortfolioPerformanceApi::TransactionSync.split_plan(plan)
  end

  def empty_plan?(plan)
    plan.create_sheet.empty? && plan.update_sheet.empty? &&
      plan.create_portfolio.empty? && plan.update_portfolio.empty?
  end

  def preview_account(account_name, sheet_plan, portfolio_plan, page_size)
    portfolio_lines, sheet_lines = PortfolioPerformanceApi::SyncPreview.lines_for(
      PortfolioPerformanceApi::TransactionSync::Plan.new(
        create_sheet: sheet_plan.create_sheet,
        update_sheet: sheet_plan.update_sheet,
        create_portfolio: portfolio_plan.create_portfolio,
        update_portfolio: portfolio_plan.update_portfolio
      )
    )
    PortfolioPerformanceApi::SyncPreview.new(
      account_name,
      portfolio_lines,
      sheet_lines,
      page_size: page_size,
      portfolio_counts: {
        create: portfolio_plan.create_portfolio.size,
        update: portfolio_plan.update_portfolio.size
      },
      sheet_counts: {
        create: sheet_plan.create_sheet.size,
        update: sheet_plan.update_sheet.size
      }
    ).run
  end

  def unique_titles(accounts)
    titles = PortfolioPerformanceApi::SheetsClient.unique_titles(accounts.map(&:name))
    titles.zip(accounts).to_h
  end
end

PortfolioSyncCli.main if $PROGRAM_NAME == __FILE__
