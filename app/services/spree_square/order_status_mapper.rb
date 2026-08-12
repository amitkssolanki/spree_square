module SpreeSquare
  # Applies a Square order/fulfillment status change to the mapped Spree
  # order.
  #
  # Deliberately does NOT gate on `version` being newer than what's
  # recorded, despite that being the pattern used elsewhere in this
  # extension (catalog/inventory sync). Verified directly: Square emits
  # `order.updated` and `order.fulfillment.updated` for the *same*
  # underlying mutation carrying the *same* version number — they're two
  # views of one change, not a sequence. Gating on version meant whichever
  # webhook's job happened to run first "claimed" that version, and the
  # other was dropped as "stale" even though it carried different,
  # necessary information (e.g. the fulfillment transition itself). That
  # bug was caught by testing a real cancellation end-to-end, not by
  # inspecting the code.
  #
  # Safety against duplicate/out-of-order delivery instead comes from two
  # places that don't have this problem: WebhookEvent's uniqueness on
  # Square's own event_id (exact redelivery is a no-op before this class
  # ever runs), and the state-guarded idempotent operations below (`unless
  # canceled?`, `if ready?`) — applying the same transition twice, or an
  # old one after a newer one already landed, does nothing either way.
  class OrderStatusMapper
    FULFILLMENT_SHIP_STATES = %w[COMPLETED].freeze
    # PROPOSED/RESERVED/PREPARED: kitchen-visible progress with no Spree
    # shipment-state equivalent ("food is cooking") — recorded as a friendly
    # label on the mapping, not forced into shipment_state.
    FULFILLMENT_LABEL_STATES = %w[PROPOSED RESERVED PREPARED].freeze

    def self.call(...) = new.call(...)

    def call(square_order_id:, version:, order_state: nil, fulfillment_state: nil)
      mapping = SpreeSquare::OrderMapping.find_by(square_order_id: square_order_id)
      return unless mapping

      order = mapping.order

      apply_fulfillment_state(order, fulfillment_state) if fulfillment_state
      apply_order_state(order, order_state) if order_state

      # Recorded for visibility/debugging (admin page, M8) — informational
      # only, never gates whether this call's transitions above applied.
      mapping.update!(square_version: version, last_status: fulfillment_state || order_state || mapping.last_status)
    end

    private

    def apply_fulfillment_state(order, state)
      case state
      when *FULFILLMENT_SHIP_STATES
        ship!(order)
      when 'CANCELED', 'FAILED'
        # This — not order.state — is the real-world cancel signal. Square
        # rejects setting order.state to CANCELED once a payment has been
        # processed against it ("Orders cannot be canceled after payments
        # have been processed") — confirmed by hitting that error directly.
        # A paid order that isn't happening gets its *fulfillment* canceled
        # instead (the order itself stays COMPLETED for Square's own
        # accounting); that's the signal to cancel on the Spree side too.
        cancel!(order)
      end
      # FULFILLMENT_LABEL_STATES (PROPOSED/RESERVED/PREPARED) need no
      # Spree-side action beyond the last_status the caller persists —
      # surfaced later as a friendly label on the customer's order status
      # page.
    end

    def apply_order_state(order, state)
      case state
      when 'CANCELED'
        # Still handled for the (rarer) case of a Square order canceled
        # before any payment was attached.
        cancel!(order)
      when 'COMPLETED'
        ship!(order)
      end
    end

    def cancel!(order)
      order.cancel! unless order.canceled?
    end

    def ship!(order)
      order.shipments.each { |shipment| shipment.ship! if shipment.ready? }
    end
  end
end
