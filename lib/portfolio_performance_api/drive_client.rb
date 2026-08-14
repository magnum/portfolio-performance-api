# frozen_string_literal: true

require "json"
require "base64"
require "openssl"
require "net/http"
require "uri"
require "time"

module PortfolioPerformanceApi
  class DriveClient
    TOKEN_URI = URI("https://oauth2.googleapis.com/token")
    SCOPE = "https://www.googleapis.com/auth/drive.readonly"
    FILE_URI = "https://www.googleapis.com/drive/v3/files/%s"
    SHORTCUT_MIME = "application/vnd.google-apps.shortcut"
    META_FIELDS = "id,name,modifiedTime,md5Checksum,size,mimeType,shortcutDetails"

    def initialize(credentials_json: Config.service_account_json, file_id: Config.drive_file_id)
      raise NotConfigured, "Google Drive is not configured" if credentials_json.to_s.empty? || file_id.to_s.empty?

      @credentials = JSON.parse(credentials_json)
      @file_id = file_id
      @token = nil
      @token_expires_at = Time.at(0)
    end

    def download
      meta = resolve_meta(@file_id)
      bytes = get_bytes(file_uri(meta.fetch("id"), "alt" => "media"))
      {
        bytes: bytes,
        meta: {
          source: "google_drive",
          id: meta["id"],
          name: meta["name"],
          modified_at: meta["modifiedTime"],
          md5: meta["md5Checksum"],
          size: meta["size"]&.to_i
        }
      }
    end

    private

    def resolve_meta(file_id)
      meta = get_json(file_uri(file_id, fields: META_FIELDS))
      return meta unless meta["mimeType"] == SHORTCUT_MIME

      target = meta.dig("shortcutDetails", "targetId").to_s
      raise DriveError, "Drive shortcut #{file_id} has no target" if target.empty?

      target_meta = get_json(file_uri(target, fields: META_FIELDS))
      if target_meta["mimeType"] == SHORTCUT_MIME
        raise DriveError, "nested Drive shortcuts are not supported"
      end

      target_meta
    end

    def file_uri(file_id, query = {})
      uri = URI(format(FILE_URI, file_id))
      params = { "supportsAllDrives" => "true" }.merge(query)
      uri.query = URI.encode_www_form(params)
      uri
    end

    def get_json(uri)
      response = request(uri)
      JSON.parse(response.body)
    rescue JSON::ParserError
      raise DriveError, "invalid JSON from Google Drive"
    end

    def get_bytes(uri)
      request(uri).body.b
    end

    def request(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 60

      req = Net::HTTP::Get.new(uri)
      req["Authorization"] = "Bearer #{access_token}"
      response = http.request(req)
      unless response.is_a?(Net::HTTPSuccess)
        raise DriveError, format_drive_error(response)
      end

      response
    end

    def format_drive_error(response)
      if response.code == "404"
        email = @credentials["client_email"]
        "Google Drive file not found for #{email}: #{@file_id}. " \
          "Share the file (Viewer) with that service account. " \
          "Drive returns 404 when the account has no access, even if the link opens in your browser."
      else
        "Google Drive download failed (#{response.code}): #{response.body.to_s.byteslice(0, 300)}"
      end
    end

    def access_token
      return @token if @token && Time.now < @token_expires_at

      assertion = jwt
      response = Net::HTTP.post_form(
        TOKEN_URI,
        "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion" => assertion
      )
      unless response.is_a?(Net::HTTPSuccess)
        raise DriveError, "Google token exchange failed (#{response.code}): #{response.body.to_s.byteslice(0, 300)}"
      end

      payload = JSON.parse(response.body)
      @token = payload.fetch("access_token")
      ttl = Integer(payload["expires_in"] || 3600)
      @token_expires_at = Time.now + ttl - 60
      @token
    end

    def jwt
      now = Time.now.to_i
      header = b64({ alg: "RS256", typ: "JWT" }.to_json)
      payload = b64({
        iss: @credentials.fetch("client_email"),
        scope: SCOPE,
        aud: TOKEN_URI.to_s,
        iat: now,
        exp: now + 3600
      }.to_json)
      input = "#{header}.#{payload}"
      key = self.class.signing_key(@credentials.fetch("private_key"))
      signature = b64(key.sign(OpenSSL::Digest::SHA256.new, input))
      "#{input}.#{signature}"
    end

    def self.signing_key(pem)
      OpenSSL::PKey.read(normalize_pem(pem))
    rescue OpenSSL::PKey::PKeyError => error
      raise DriveError, "invalid Google service account private key (#{error.message})"
    end

    def self.normalize_pem(pem)
      pem.to_s.gsub("\r\n", "\n").gsub('\\n', "\n")
    end

    def b64(data)
      Base64.urlsafe_encode64(data, padding: false)
    end
  end
end
