# frozen_string_literal: true

port ENV.fetch("PORT", "9292")
environment ENV.fetch("RACK_ENV", "development")
threads Integer(ENV.fetch("PUMA_MIN_THREADS", "0")), Integer(ENV.fetch("PUMA_MAX_THREADS", "5"))
workers Integer(ENV.fetch("WEB_CONCURRENCY", "0"))
preload_app!
