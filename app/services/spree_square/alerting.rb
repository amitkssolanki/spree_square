module SpreeSquare
  # One place for "this needs a human" — used when a job exhausts its
  # retries. Reports to Sentry (already in this app's stack) when available,
  # always logs at error level regardless so nothing depends on Sentry being
  # configured to at least be visible in the server log.
  class Alerting
    def self.capture(error, context: {})
      context = { source: 'spree_square' }.merge(context.is_a?(String) ? { area: context } : context)

      Rails.logger.error("[SpreeSquare] #{context[:area] || 'error'}: #{error.class}: #{error.message}")

      return unless defined?(Sentry)

      Sentry.capture_exception(error, extra: context)
    end
  end
end
