# frozen_string_literal: true

module PortfolioPerformanceApi
  class Error < StandardError; end
  class Unauthorized < Error; end
  class IncorrectPassword < Error; end
  class NotAPortfolioFile < Error; end
  class NotConfigured < Error; end
  class DriveError < Error; end
end
