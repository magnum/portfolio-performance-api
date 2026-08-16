#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "dotenv"
require "fileutils"
require "tty-prompt"

root = File.expand_path("..", __dir__)
Dotenv.load(File.join(root, ".env"))
$LOAD_PATH.unshift(File.join(root, "lib"))

require "portfolio_performance_api/errors"
require "portfolio_performance_api/decryptor"
require "portfolio_performance_api/file_reader"
require "portfolio_performance_api/proto/client_pb"
require "portfolio_performance_api/config"
require "portfolio_performance_api/fineco_xls"
require "portfolio_performance_api/fineco_import"
require "portfolio_performance_api/portfolio_store"
require "portfolio_performance_api/checkbox_menu"

module FinecoImportCli
  module_function

  def main(argv)
    account_name, portfolio_path, xls_path = argv
    if account_name.to_s.empty? || portfolio_path.to_s.empty? || xls_path.to_s.empty? || argv.size != 3
      warn "Usage: ruby utils/import-fineco.rb ACCOUNT_NAME PORTFOLIO_FILE FINECO_XLS"
      warn "Example: ruby utils/import-fineco.rb EUR010069756 $HOME/finance/portfolio1.portfolio ./movements.xlsx"
      exit 1
    end

    portfolio_path = File.expand_path(portfolio_path)
    xls_path = File.expand_path(xls_path)

    abort "portfolio file not found: #{portfolio_path}" unless File.file?(portfolio_path)
    abort "Fineco XLS not found: #{xls_path}" unless File.file?(xls_path)

    prompt = TTY::Prompt.new
    password = portfolio_password(portfolio_path, prompt)
    loaded = PortfolioPerformanceApi::PortfolioStore.load(portfolio_path, password: password)
    account = PortfolioPerformanceApi::FinecoImport.find_account(loaded.client, account_name)
    abort "deposit account not found: #{account_name}" unless account

    rows = PortfolioPerformanceApi::FinecoXls.parse(xls_path)
    last_date = PortfolioPerformanceApi::FinecoImport.last_transaction_date(loaded.client, account.uuid)
    candidates = PortfolioPerformanceApi::FinecoImport.newer_than(rows, last_date)

    if candidates.empty?
      if last_date
        warn "no Fineco transactions after #{last_date} for #{account.name}"
      else
        warn "no Fineco transactions found in #{xls_path}"
      end
      exit 0
    end

    puts "Account #{account.name} (#{account.currencyCode})"
    puts last_date ? "Last portfolio transaction: #{last_date}" : "No dated transactions on this account yet"
    puts "Use ↑/↓ arrows to navigate, SPACE to select/deselect, ENTER to confirm"
    puts

    selected_indexes = PortfolioPerformanceApi::CheckboxMenu.new(candidates.map { |row| format_row(row) }).run
    selected = selected_indexes.map { |index| candidates[index] }
    if selected.empty?
      warn "no transactions selected"
      exit 0
    end

    unless prompt.yes?("are you sure you want to import #{selected.size} transactions?")
      warn "aborted"
      exit 0
    end

    backup = PortfolioPerformanceApi::PortfolioStore.backup_path(portfolio_path)
    FileUtils.cp(portfolio_path, backup)
    PortfolioPerformanceApi::FinecoImport.append!(loaded.client, account, selected)
    PortfolioPerformanceApi::PortfolioStore.save(loaded)
    puts "Backup: #{backup}"
    puts "Imported #{selected.size} transactions into #{portfolio_path}"
    puts "Reopen the file in Portfolio Performance (close it first if it is already open)."
  rescue PortfolioPerformanceApi::Error, ArgumentError => error
    abort error.message
  end

  def portfolio_password(path, prompt)
    raw = File.binread(path).b
    return ENV["PORTFOLIO_PASSWORD"] unless PortfolioPerformanceApi::Decryptor.encrypted?(raw)

    password = ENV["PORTFOLIO_PASSWORD"]
    return password unless password.nil? || password.empty?

    prompt.mask("Portfolio password:")
  end

  def format_row(row)
    amount = format_cents(row.amount_cents)
    sign = row.type.to_s == "REMOVAL" ? "-" : "+"
    note = row.description
    note = "#{note[0, 90]}…" if note.size > 90
    "#{row.date}  #{row.type.to_s.ljust(8)}  #{sign}#{amount.rjust(12)}  #{note}"
  end

  def format_cents(cents)
    whole, frac = cents.abs.divmod(100)
    grouped = whole.to_s.reverse.gsub(/(\d{3})(?=\d)/, "\\1.").reverse
    "#{grouped},#{frac.to_s.rjust(2, "0")}"
  end
end

FinecoImportCli.main(ARGV) if $PROGRAM_NAME == __FILE__
