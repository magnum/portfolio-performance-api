# frozen_string_literal: true

require_relative "test_helper"

class DecryptorTest < Minitest::Test
  include PortfolioFixtures

  def test_roundtrip_xml
    encrypted = encrypted_xml
    payload = PortfolioPerformanceApi::Decryptor.decrypt(encrypted, "secret")
    assert_equal 1, payload.content_type
    assert_equal 70, payload.version
    assert payload.zip_bytes.start_with?("PK")
  end

  def test_wrong_password
    encrypted = encrypted_xml
    assert_raises(PortfolioPerformanceApi::IncorrectPassword) do
      PortfolioPerformanceApi::Decryptor.decrypt(encrypted, "wrong")
    end
  end

  def test_file_reader_encrypted_xml
    result = PortfolioPerformanceApi::FileReader.read(encrypted_xml, password: "secret")
    assert_equal :xml, result.format
    assert_includes result.bytes, "Conto corrente"
  end

  def test_file_reader_encrypted_protobuf
    result = PortfolioPerformanceApi::FileReader.read(encrypted_protobuf, password: "secret")
    assert_equal :protobuf, result.format
  end
end
