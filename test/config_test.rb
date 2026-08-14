# frozen_string_literal: true

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
end
