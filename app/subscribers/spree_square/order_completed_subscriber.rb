module SpreeSquare
  # Events & Subscribers is the preferred pattern for this kind of side
  # effect (per this app's own CLAUDE.md conventions) — react to
  # order.completed without touching Spree::Order itself.
  class OrderCompletedSubscriber < Spree::Subscriber
    subscribes_to 'order.completed'

    def handle(event)
      order = Spree::Order.find_by_prefix_id(event.payload['id'])
      return unless order

      SpreeSquare::OrderPushJob.perform_later(order.id)
    end
  end
end
