module SpreeSquare
  # Events & Subscribers is the preferred pattern for this kind of side
  # effect (per this app's own CLAUDE.md conventions) — react to
  # order.completed without touching Spree::Order itself.
  class OrderCompletedSubscriber < Spree::Subscriber
    subscribes_to 'order.completed'

    def handle(event)
      order = Spree::Order.find_by_prefix_id(event.payload['id'])
      return unless order

      # Order pushing is switched off for the location this order would go
      # to (SpreePos::Location#order_push_enabled). Not enqueueing is only an
      # optimisation and a clearer log line: the push job re-checks the
      # switch itself before any external write, so a job enqueued before a
      # disable is refused too.
      if SpreePos::OrderPushGate.refuses?(order)
        Rails.logger.warn("[SpreeSquare] order_push_disabled: not enqueueing a push for order #{order.number}")
        return
      end

      SpreeSquare::OrderPushJob.perform_later(order.id)
    end
  end
end
