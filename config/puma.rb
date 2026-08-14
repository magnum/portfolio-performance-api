# frozen_string_literal: true

rack_env = ENV.fetch("RACK_ENV", "development")

port ENV.fetch("PORT", "9292")
environment rack_env
threads Integer(ENV.fetch("PUMA_MIN_THREADS", "0")), Integer(ENV.fetch("PUMA_MAX_THREADS", "5"))
workers Integer(ENV.fetch("WEB_CONCURRENCY", "0"))

# Reloader in development needs the app loaded per process, not pre-forked.
preload_app! if rack_env == "production"
