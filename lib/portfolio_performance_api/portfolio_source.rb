# frozen_string_literal: true

module PortfolioPerformanceApi
  class PortfolioSource
    def initialize(config: Config, drive_client: nil)
      @config = config
      @drive_client = drive_client
    end

    def fetch
      if @config.drive_configured?
        (@drive_client || DriveClient.new).download
      elsif @config.local_file_configured?
        path = @config.portfolio_file
        {
          bytes: File.binread(path),
          meta: {
            source: "local",
            path: path,
            modified_at: File.mtime(path).utc.iso8601,
            size: File.size(path)
          }
        }
      else
        raise NotConfigured,
              "configure PORTFOLIO_GOOGLE_DRIVE_FILE_ID + service account, or PORTFOLIO_FILE"
      end
    end
  end
end
