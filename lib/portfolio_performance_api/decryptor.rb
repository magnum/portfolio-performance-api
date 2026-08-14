# frozen_string_literal: true

require "openssl"

module PortfolioPerformanceApi
  # Decrypts Portfolio Performance AES-encrypted .portfolio files.
  #
  # Layout (see ClientFactory.Decryptor in the upstream Java app):
  #   signature 9 bytes "PORTFOLIO"
  #   method    1 byte  (0 = AES-128, 1 = AES-256)
  #   iv       16 bytes
  #   ciphertext = AES-CBC-PKCS5( contentType:int32be, version:int32be, zip )
  class Decryptor
    SIGNATURE = "PORTFOLIO"
    SALT = [112, 67, 103, 107, -92, -125, -112, -95, -97, -114, 117, -56, -53, -69, -25, -28].pack("c*")
    ITERATIONS = 65_536
    IV_LENGTH = 16
    MAX_VERSION = 200

    Payload = Struct.new(:content_type, :version, :zip_bytes, keyword_init: true)

    def self.encrypted?(bytes)
      bytes.start_with?(SIGNATURE)
    end

    def self.decrypt(bytes, password)
      raise NotAPortfolioFile, "not an encrypted portfolio file" unless encrypted?(bytes)
      raise IncorrectPassword, "portfolio password is required" if password.nil? || password.empty?

      method = bytes.getbyte(SIGNATURE.bytesize)
      key_len = method == 1 ? 32 : 16
      iv = bytes.byteslice(SIGNATURE.bytesize + 1, IV_LENGTH)
      ciphertext = bytes.byteslice(SIGNATURE.bytesize + 1 + IV_LENGTH..)
      raise NotAPortfolioFile, "truncated encrypted portfolio file" if iv.nil? || iv.bytesize != IV_LENGTH || ciphertext.nil? || ciphertext.empty?

      key = OpenSSL::KDF.pbkdf2_hmac(password, salt: SALT, iterations: ITERATIONS, length: key_len, hash: "SHA1")
      cipher = OpenSSL::Cipher::AES.new(key_len * 8, :CBC)
      cipher.decrypt
      cipher.key = key
      cipher.iv = iv

      begin
        plaintext = cipher.update(ciphertext) + cipher.final
      rescue OpenSSL::Cipher::CipherError
        raise IncorrectPassword, "incorrect portfolio password"
      end

      content_type, version = plaintext.unpack("l>l>")
      if content_type < 1 || content_type > 2 || version < 1 || version > MAX_VERSION
        raise IncorrectPassword, "incorrect portfolio password"
      end

      Payload.new(content_type: content_type, version: version, zip_bytes: plaintext.byteslice(8..))
    end

    def self.encrypt(zip_bytes, password, aes256: true, content_type: 2, version: 70)
      key_len = aes256 ? 32 : 16
      key = OpenSSL::KDF.pbkdf2_hmac(password, salt: SALT, iterations: ITERATIONS, length: key_len, hash: "SHA1")
      cipher = OpenSSL::Cipher::AES.new(key_len * 8, :CBC)
      cipher.encrypt
      cipher.key = key
      iv = cipher.random_iv

      header = [content_type, version].pack("l>l>")
      ciphertext = cipher.update(header + zip_bytes) + cipher.final

      SIGNATURE.b + [aes256 ? 1 : 0].pack("C") + iv + ciphertext
    end
  end
end
