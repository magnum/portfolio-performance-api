# frozen_string_literal: true

module PortfolioPerformanceApi
  module Config
    module_function

    def api_key
      required("API_KEY")
    end

    def api_key_header
      env("API_KEY_HEADER", "X-Api-Key")
    end

    def portfolio_password
      env("PORTFOLIO_PASSWORD")
    end

    def drive_file_id
      raw = env("GOOGLE_DRIVE_FILE_ID")
      return if raw.nil? || raw.empty?

      extract_drive_id(raw)
    end

    def service_account_json
      inline = env("GOOGLE_SERVICE_ACCOUNT_JSON")
      return inline unless inline.nil? || inline.empty?

      path = env("GOOGLE_APPLICATION_CREDENTIALS")
      return File.read(path) if path && !path.empty? && File.file?(path)

      nil
    end

    def portfolio_file
      env("PORTFOLIO_FILE")
    end

    def cache_ttl
      minutes = Integer(env("CACHE_TTL_MINUTES", "15"))
      minutes * 60
    end

    def include_retired?
      env("INCLUDE_RETIRED", "true") != "false"
    end

    def port
      Integer(env("PORT", "9292"))
    end

    def drive_configured?
      !drive_file_id.to_s.empty? && !service_account_json.to_s.empty?
    end

    def local_file_configured?
      path = portfolio_file
      path && !path.empty? && File.file?(path)
    end

    def extract_drive_id(value)
      value[/\/d\/([a-zA-Z0-9_-]+)/, 1] ||
        value[/[?&]id=([a-zA-Z0-9_-]+)/, 1] ||
        value
    end

    def env(name, default = nil)
      value = ENV[name]
      return default if value.nil? || value.empty?

      value
    end

    def required(name)
      value = ENV[name]
      raise NotConfigured, "missing env #{name}" if value.nil? || value.empty?

      value
    end
  end
end
