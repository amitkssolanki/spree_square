module SpreeSquare
  # A failed order push is the worst failure mode in this whole system —
  # payment already taken, kitchen never sees the ticket. Retries with
  # backoff; if genuinely exhausted, this is the one alert in the whole
  # extension that should always reach a human regardless of Sentry config,
  # which is why Alerting always logs at error level even when Sentry isn't
  # available.
  class OrderPushJob < BaseJob
    # `find_by`, never `find_or_initialize_by` (Phase 3, this session's
    # write-path audit): SpreePos::OrderPush#call now always creates the
    # OrderMapping (with a real pos_connection/pos_location already set)
    # BEFORE ever calling the adapter, so the common case -- a
    # StandardError raised from adapter.push(order) -- always finds an
    # existing, already-fully-populated mapping here. But if the error
    # happens before that row exists at all (OrderMapping.find_or_create!
    # itself raising, or the rarer case of a store with no resolvable
    # connection where #call returns nil without ever pushing), building
    # a BRAND NEW mapping here via find_or_initialize_by would try to
    # `save!` one with nil pos_connection_id/pos_location_id -- both NOT
    # NULL after the tighten migration -- raising
    # ActiveRecord::NotNullViolation from inside this retry-exhaustion
    # handler itself. That would be bad on its own, but critically it
    # would also stop the `Alerting.capture` call below from ever running
    # -- the one alert this class's own comment above promises "should
    # always reach a human regardless of Sentry config." The rescue below
    # is the second half of that same guarantee: even an unexpected
    # failure while touching the mapping must never suppress the alert.
    retry_on StandardError, wait: :polynomially_longer, attempts: 5 do |job, error|
      order = Spree::Order.find_by(id: job.arguments.first)
      begin
        SpreePos::OrderMapping.find_by(order: order)&.mark_failed!(error) if order
      rescue StandardError => mark_failed_error
        Rails.logger.error("[SpreeSquare] OrderPushJob: failed to record push failure on the OrderMapping: " \
                            "#{mark_failed_error.class}: #{mark_failed_error.message}")
      end
      SpreePos::Alerting.capture(
        error,
        context: { area: 'order_push', order_number: order&.number }
      )
    end

    def perform(order_id)
      order = Spree::Order.find(order_id)
      SpreePos::OrderPush.call(order, adapter: SpreeSquare::OrderAdapter.new, order_idempotency_key: true)
    end
  end
end
