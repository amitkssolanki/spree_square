module SpreeSquare
  # Pushes a completed Spree order into Square as a paid ticket: creates the
  # Square Order, then records the payment Spree already collected as an
  # EXTERNAL payment against it (Square's own first-class mechanism for
  # "paid somewhere else" — its docs use exactly this "food delivery
  # service" scenario as the example). No Square payment gateway needed for
  # this to work.
  #
  # Charges exactly what Square computed as the order's own total_money,
  # read back from the create-order response, rather than recomputing a
  # total independently — guarantees the payment can never mismatch the
  # order it's attached to.
  class OrderPusher
    def self.call(...) = new.call(...)

    def call(order)
      client = SpreeSquare::Client.instance
      mapping = SpreeSquare::OrderMapping.find_or_initialize_by(order: order)

      square_order = create_order(client, order)
      mapping.update!(
        square_order_id: square_order.id,
        square_location_id: square_order.location_id,
        square_version: square_order.version,
        last_status: square_order.state
      )

      payment = record_external_payment(client, order, square_order)

      # Attaching a fully-covering payment can advance Square's own order
      # state immediately (e.g. OPEN -> COMPLETED) — re-fetch so the mapping
      # reflects that instead of the pre-payment snapshot. M6 keeps this
      # correct going forward via order.updated webhooks; this just avoids a
      # misleading stale status in the window before the first one arrives.
      refreshed = client.orders.get(order_id: square_order.id).order
      mapping.update!(
        square_payment_id: payment.id,
        square_version: refreshed.version,
        last_status: refreshed.state
      )

      mapping
    end

    private

    def create_order(client, order)
      payload = SpreeSquare::OrderBuilder.call(order)
      response = client.orders.create(
        idempotency_key: "spree-order-#{order.number}",
        order: payload
      )
      response.order
    end

    def record_external_payment(client, order, square_order)
      total = square_order.total_money
      response = client.payments.create(
        source_id: 'EXTERNAL',
        idempotency_key: "spree-payment-#{order.number}",
        amount_money: { amount: total.amount, currency: total.currency },
        order_id: square_order.id,
        external_details: { type: 'OTHER', source: 'Spree checkout' }
      )
      response.payment
    end
  end
end
