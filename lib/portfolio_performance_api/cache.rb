# frozen_string_literal: true

module PortfolioPerformanceApi
  class Cache
    Entry = Struct.new(:payload, :cached_at, :expires_at, keyword_init: true)

    def initialize(ttl: Config.cache_ttl)
      @ttl = ttl
      @mutex = Mutex.new
      @entry = nil
    end

    def fetch(force: false)
      unless force
        current = @entry
        return decorate(current, hit: true) if current && Time.now < current.expires_at
      end

      @mutex.synchronize do
        unless force
          current = @entry
          return decorate(current, hit: true) if current && Time.now < current.expires_at
        end

        payload = yield
        now = Time.now.utc
        @entry = Entry.new(payload: payload, cached_at: now, expires_at: now + @ttl)
        decorate(@entry, hit: false)
      end
    end

    def clear
      @mutex.synchronize { @entry = nil }
    end

    private

    def decorate(entry, hit:)
      entry.payload.merge(
        cached: hit,
        cached_at: entry.cached_at.iso8601,
        expires_at: entry.expires_at.iso8601
      )
    end
  end
end
