# frozen_string_literal: true

require "base64"
require_relative "test_helper"

class ConfigTest < Minitest::Test
  def test_extract_drive_id_from_open_url
    url = "https://drive.google.com/open?id=1uPtEx-cFyHT6l0_Iwd07ycQ2gAi5wBbb&usp=drive_fs"
    assert_equal "1uPtEx-cFyHT6l0_Iwd07ycQ2gAi5wBbb",
                 PortfolioPerformanceApi::Config.extract_drive_id(url)
  end

  def test_extract_drive_id_from_file_url
    url = "https://drive.google.com/file/d/1uPtEx-cFyHT6l0_Iwd07ycQ2gAi5wBbb/view"
    assert_equal "1uPtEx-cFyHT6l0_Iwd07ycQ2gAi5wBbb",
                 PortfolioPerformanceApi::Config.extract_drive_id(url)
  end

  def test_extract_drive_id_from_bare_id
    id = "1uPtEx-cFyHT6l0_Iwd07ycQ2gAi5wBbb"
    assert_equal id, PortfolioPerformanceApi::Config.extract_drive_id(id)
  end

  def test_sync_skip_rows_defaults_to_zero
    previous = ENV["SYNC_GOOGLE_DRIVE_FILE_SKIP_ROWS"]
    ENV.delete("SYNC_GOOGLE_DRIVE_FILE_SKIP_ROWS")
    assert_equal 0, PortfolioPerformanceApi::Config.sync_skip_rows
    ENV["SYNC_GOOGLE_DRIVE_FILE_SKIP_ROWS"] = "13"
    assert_equal 13, PortfolioPerformanceApi::Config.sync_skip_rows
  ensure
    if previous.nil?
      ENV.delete("SYNC_GOOGLE_DRIVE_FILE_SKIP_ROWS")
    else
      ENV["SYNC_GOOGLE_DRIVE_FILE_SKIP_ROWS"] = previous
    end
  end

  def test_sync_rows_chunk_defaults_to_one_hundred
    previous = ENV["SYNC_GOOGLE_DRIVE_ROWS_CHUNK"]
    ENV.delete("SYNC_GOOGLE_DRIVE_ROWS_CHUNK")
    assert_equal 100, PortfolioPerformanceApi::Config.sync_rows_chunk
    ENV["SYNC_GOOGLE_DRIVE_ROWS_CHUNK"] = "50"
    assert_equal 50, PortfolioPerformanceApi::Config.sync_rows_chunk
  ensure
    if previous.nil?
      ENV.delete("SYNC_GOOGLE_DRIVE_ROWS_CHUNK")
    else
      ENV["SYNC_GOOGLE_DRIVE_ROWS_CHUNK"] = previous
    end
  end

  def test_sync_preview_rows_defaults_to_twenty
    previous = ENV["SYNC_GOOGLE_DRIVE_PREVIEW_ROWS"]
    ENV.delete("SYNC_GOOGLE_DRIVE_PREVIEW_ROWS")
    assert_equal 20, PortfolioPerformanceApi::Config.sync_preview_rows
    ENV["SYNC_GOOGLE_DRIVE_PREVIEW_ROWS"] = "8"
    assert_equal 8, PortfolioPerformanceApi::Config.sync_preview_rows
  ensure
    if previous.nil?
      ENV.delete("SYNC_GOOGLE_DRIVE_PREVIEW_ROWS")
    else
      ENV["SYNC_GOOGLE_DRIVE_PREVIEW_ROWS"] = previous
    end
  end

  def test_sync_test_drive_file_id_from_spreadsheet_url
    previous = ENV["SYNC_GOOGLE_DRIVE_FILE_ID_TEST"]
    ENV["SYNC_GOOGLE_DRIVE_FILE_ID_TEST"] = "https://docs.google.com/spreadsheets/d/1SyncTestFileId/edit"
    assert_equal "1SyncTestFileId", PortfolioPerformanceApi::Config.sync_test_drive_file_id
  ensure
    if previous.nil?
      ENV.delete("SYNC_GOOGLE_DRIVE_FILE_ID_TEST")
    else
      ENV["SYNC_GOOGLE_DRIVE_FILE_ID_TEST"] = previous
    end
  end

  def test_sync_drive_file_id_from_spreadsheet_url
    previous = ENV["SYNC_GOOGLE_DRIVE_FILE_ID"]
    ENV["SYNC_GOOGLE_DRIVE_FILE_ID"] = "https://docs.google.com/spreadsheets/d/1SyncFileIdExample/edit"
    assert_equal "1SyncFileIdExample", PortfolioPerformanceApi::Config.sync_drive_file_id
  ensure
    ENV["SYNC_GOOGLE_DRIVE_FILE_ID"] = previous
  end

  def test_service_account_json_accepts_base64
    json = { "type" => "service_account", "private_key" => "x" }.to_json
    previous = ENV["GOOGLE_SERVICE_ACCOUNT_JSON"]
    ENV["GOOGLE_SERVICE_ACCOUNT_JSON"] = Base64.strict_encode64(json)
    assert_equal json, PortfolioPerformanceApi::Config.service_account_json
  ensure
    ENV["GOOGLE_SERVICE_ACCOUNT_JSON"] = previous
  end

  def test_service_account_json_strips_wrapping_quotes
    json = { "type" => "service_account" }.to_json
    previous = ENV["GOOGLE_SERVICE_ACCOUNT_JSON"]
    ENV["GOOGLE_SERVICE_ACCOUNT_JSON"] = "'#{json}'"
    assert_equal json, PortfolioPerformanceApi::Config.service_account_json
  ensure
    ENV["GOOGLE_SERVICE_ACCOUNT_JSON"] = previous
  end
end
