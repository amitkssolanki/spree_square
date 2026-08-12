module SpreeSquare
  # A failed order push is the worst failure mode in this whole system —
  # payment already taken, kitchen never sees the ticket. Retries with
  # backoff; if genuinely exhausted, this is the one alert in the whole
  # extension that should always reach a human regardless of Sentry config,
  # which is why Alerting always logs at error level even when Sentry isn't
  # available.
  class OrderPushJob < BaseJob
    retry_on StandardError, wait: :polynomially_longer, attempts: 5 do |job, error|
      order = Spree::Order.find_by(id: job.arguments.first)
      SpreeSquare::OrderMapping.find_or_initialize_by(order: order).mark_failed!(error) if order
      SpreeSquare::Alerting.capture(
        error,
        context: { area: 'order_push', order_number: order&.number }
      )
    end

    def perform(order_id)
      order = Spree::Order.find(order_id)
      SpreeSquare::OrderPusher.call(order)
    end
  end
end
