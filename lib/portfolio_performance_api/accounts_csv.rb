# frozen_string_literal: true

require "csv"

module PortfolioPerformanceApi
  module AccountsCsv
    HEADERS = %w[uuid kind name currency retired balance balance_cents reference_account_uuid].freeze

    module_function

    def generate(payload, locale: "en")
      locale = normalize_locale(locale)
      accounts = Array(payload[:accounts] || payload["accounts"])
      CSV.generate(**csv_options) do |csv|
        csv << HEADERS
        accounts.each do |row|
          csv << serialize_row(row, locale)
        end
      end
    end

    def csv_options
      {
        encoding: Encoding::UTF_8,
        col_sep: ";",
        row_sep: "\r\n",
        force_quotes: false
      }
    end

    def serialize_row(row, locale)
      row = stringify_keys(row)
      [
        row["uuid"],
        row["kind"],
        row["name"],
        row["currency"],
        boolean(row["retired"]),
        decimal(row["balance"], locale),
        row["balance_cents"],
        row["reference_account_uuid"]
      ]
    end

    def stringify_keys(row)
      row.to_h { |key, value| [key.to_s, value] }
    end

    def boolean(value)
      value ? "TRUE" : "FALSE"
    end

    def decimal(value, locale)
      formatted = format("%.2f", Float(value))
      return formatted unless locale == "it"

      formatted.tr(".", ",")
    end

    def normalize_locale(value)
      code = value.to_s.strip.downcase.split(/[-_]/, 2).first
      code == "it" ? "it" : "en"
    end

    private_class_method :csv_options, :serialize_row, :stringify_keys, :boolean, :decimal
  end
end
