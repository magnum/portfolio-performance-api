# frozen_string_literal: true

require "digest"
require "rack/utils"

module PortfolioPerformanceApi
  module Auth
    module_function

    def require!(env)
      provided = api_key_from(env)
      raise Unauthorized, "missing API key" if provided.nil? || provided.empty?
      raise Unauthorized, "invalid API key" unless secure_compare(provided, Config.api_key)
    end

    def api_key_from(env)
      from_header(env) || from_authorization(env) || from_query(env)
    end

    def from_header(env)
      header = Config.api_key_header
      rack_name = "HTTP_#{header.upcase.tr("-", "_")}"
      value = env[rack_name]
      present(value)
    end

    def from_authorization(env)
      authorization = env["HTTP_AUTHORIZATION"].to_s
      return if authorization.empty?
      return authorization.sub(/\ABearer\s+/i, "") if authorization.match?(/\ABearer\s+/i)

      authorization
    end

    def from_query(env)
      query = Rack::Utils.parse_query(env["QUERY_STRING"].to_s)
      value = query["apikey"]
      value = value.first if value.is_a?(Array)
      present(value)
    end

    def present(value)
      return if value.nil? || value.empty?

      value
    end

    def secure_compare(a, b)
      Rack::Utils.secure_compare(Digest::SHA256.hexdigest(a), Digest::SHA256.hexdigest(b))
    end
  end
end
