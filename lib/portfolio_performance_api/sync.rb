# frozen_string_literal: true

require_relative "errors"
require_relative "decryptor"
require_relative "file_reader"
require_relative "proto/client_pb"
require_relative "config"
require_relative "drive_client"
require_relative "portfolio_store"
require_relative "sheets_client"
require_relative "transaction_sync"
require_relative "sync_preview"

module PortfolioPerformanceApi
  class Sync
    def self.run
      new.run
    end

    def run
      portfolio_id = Config.drive_file_id
      spreadsheet_id = Config.sync_drive_file_id
      password = Config.portfolio_password
      abort "missing PORTFOLIO_GOOGLE_DRIVE_FILE_ID" if portfolio_id.to_s.empty?
      abort "missing SYNC_GOOGLE_DRIVE_FILE_ID" if spreadsheet_id.to_s.empty?
      abort "missing GOOGLE_SERVICE_ACCOUNT_JSON" if Config.service_account_json.to_s.empty?

      session = DriveClient.new(file_id: portfolio_id, scope: DriveClient::SYNC_SCOPE)
      sheets = SheetsClient.new(session: session, spreadsheet_id: spreadsheet_id)

      downloaded = session.download
      loaded = PortfolioStore.load_bytes(
        downloaded.fetch(:bytes),
        password: password,
        path: downloaded.dig(:meta, :name)
      )
      skip_rows = Config.sync_skip_rows
      chunk_size = Config.sync_rows_chunk
      preview_rows = Config.sync_preview_rows
      names = TransactionSync.uuid_names(loaded.client)
      known_sheets = sheets.sheet_titles
      portfolio_changed = false

      unique_titles(TransactionSync.vehicles(loaded.client)).each do |title, vehicle|
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
            TransactionSync.apply_sheet(
              sheets, title, sheet_plan, skip_rows: skip_rows, chunk_size: chunk_size, raw_rows: raw_rows
            )
            puts "#{vehicle.name}: spreadsheet written"
          end
        end
        if %w[P B].include?(choice)
          records = portfolio_plan.create_portfolio + portfolio_plan.update_portfolio
          unless records.empty?
            applied = TransactionSync.apply_portfolio!(
              loaded.client,
              vehicle,
              records
            )
            portfolio_changed ||= applied.positive?
            names = TransactionSync.uuid_names(loaded.client)
            puts "#{vehicle.name}: portfolio updated"
          end
        end
      end

      if portfolio_changed
        session.upload(PortfolioStore.dump(loaded))
        puts "Uploaded portfolio #{downloaded.dig(:meta, :name)}"
      else
        puts "Portfolio file unchanged"
      end
    rescue Error, ArgumentError => error
      abort error.message
    end

    private

    def account_plans(client, vehicle, raw_rows, names, skip_rows)
      plan = TransactionSync.account_plan(
        client, vehicle, raw_rows, names: names, skip_rows: skip_rows
      )
      TransactionSync.split_plan(plan)
    end

    def empty_plan?(plan)
      plan.create_sheet.empty? && plan.update_sheet.empty? &&
        plan.create_portfolio.empty? && plan.update_portfolio.empty?
    end

    def preview_account(account_name, sheet_plan, portfolio_plan, page_size)
      portfolio_lines, sheet_lines = SyncPreview.lines_for(
        TransactionSync::Plan.new(
          create_sheet: sheet_plan.create_sheet,
          update_sheet: sheet_plan.update_sheet,
          create_portfolio: portfolio_plan.create_portfolio,
          update_portfolio: portfolio_plan.update_portfolio
        )
      )
      SyncPreview.new(
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
      titles = SheetsClient.unique_titles(accounts.map(&:name))
      titles.zip(accounts).to_h
    end
  end
end
