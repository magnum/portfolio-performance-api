# frozen_string_literal: true

require_relative "test_helper"

class DriveClientTest < Minitest::Test
  def test_signing_key_accepts_escaped_newlines
    key = OpenSSL::PKey::RSA.generate(2048)
    pem = key.private_to_pem
    escaped = pem.gsub("\n", "\\n")

    loaded = PortfolioPerformanceApi::DriveClient.signing_key(escaped)
    assert loaded.private?
    assert_equal key.to_der, loaded.to_der
  end
end
