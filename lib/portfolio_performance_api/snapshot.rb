# frozen_string_literal: true

module PortfolioPerformanceApi
  class Snapshot
    def initialize(source: PortfolioSource.new, cache: Cache.new, config: Config)
      @source = source
      @cache = cache
      @config = config
    end

    def accounts(nocache: false)
      @cache.fetch(force: nocache) { load }
    end

    private

    def load
      downloaded = @source.fetch
      parsed = FileReader.read(downloaded.fetch(:bytes), password: @config.portfolio_password)
      client = Parser.parse(parsed)
      Balances.compute(client, include_retired: @config.include_retired?).merge(
        file: downloaded.fetch(:meta),
        format: parsed.format.to_s
      )
    end
  end
end
