module SpreeSquare
  # Square's side of the provider-neutral order-push contract
  # (SpreePos::OrderPush calls #push; nothing here knows about push_state,
  # retries, or the ambiguous-outcome state machine -- that bookkeeping
  # moved to SpreePos::OrderMapping/OrderPush in Phase 2D, step 16b).
  #
  # #build_payload was SpreeSquare::OrderBuilder (step 16a); #push was
  # SpreeSquare::OrderPusher (step 16b) -- both moved here verbatim (logic
  # unchanged) as the two halves of one Square-specific adapter.
  class OrderAdapter
    # Builds the Square CreateOrder payload for a completed Spree::Order.
    # Deliberately omits discounts — nothing for Square's own discount engine
    # to add on top of what we send and create a mismatch. Everything Square
    # actually charges (items, modifiers, delivery fee, tax) is now sent
    # explicitly, so `total_money` in the create-order response is fully
    # derived from this payload — never independently computed by Square —
    # which is what lets #push trust it as the EXTERNAL payment amount.
    #
    # Item AND delivery-fee sales tax are both sent (see #build_line_item /
    # #build_delivery_line_item / #resolve_square_tax_ids_for_category) —
    # Square requires an explicit order-level `taxes` array plus a per-line-item
    # `applied_taxes` reference; simply pointing a line item's catalog_object_id
    # at a taxed CatalogItem does NOT make Square auto-compute tax on it. Found
    # live, comparing a real order confirmation against its Square receipt:
    # Spree charged $19.42 ($9.99 item + $7.99 delivery + $1.44 combined tax),
    # Square's own ticket/payment showed a bare $9.99 with none of that.
    #
    # The delivery fee is pushed as an ad-hoc line item — no `catalog_object_id`,
    # just a name and whatever `shipment.cost` actually is for this order
    # (DoorDash/Uber Direct fees are live-quoted per order/distance, so there's
    # no fixed CatalogItem to reference; this is the same "unmapped variant"
    # fallback shape #build_line_item already uses, not a new mechanism). No
    # Square-side catalog/POS configuration is needed for this — ad-hoc line
    # items accept any price at request time.
    def build_payload(order)
      location_mapping = location_mapping_for(order)
      raise "No Square location mapped for order #{order.number}" unless location_mapping

      # Memoized per tax_category (not per line item) — an order commonly has
      # several line items sharing the same product/tax_category, and this
      # avoids re-querying TaxCategoryMapping for each one.
      @tax_ids_by_category_id = {}
      built_line_items = order.line_items.map { |line_item| build_line_item(line_item) }
      built_line_items += order.shipments.filter_map { |shipment| build_delivery_line_item(shipment) }

      {
        location_id: location_mapping.square_location_id,
        reference_id: order.number,
        line_items: built_line_items,
        taxes: built_line_items.flat_map { |li| li[:applied_taxes]&.map { |t| t[:tax_uid] } || [] }.uniq.map { |id| build_order_tax(id) }.presence,
        fulfillments: [build_fulfillment(order)]
      }.compact
    end

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
    #
    # Returns a SpreePos::Orders::PushResult (not a mapping — recording the
    # outcome onto a SpreePos::OrderMapping is SpreePos::OrderPush's job, so
    # this class stays a plain provider adapter with no push_state/retry
    # awareness of its own).
    def push(order)
      client = SpreeSquare::Client.instance

      square_order = create_order(client, order)
      payment = record_external_payment(client, order, square_order)

      # Attaching a fully-covering payment can advance Square's own order
      # state immediately (e.g. OPEN -> COMPLETED) — re-fetch so the result
      # reflects that instead of the pre-payment snapshot. M6 keeps this
      # correct going forward via order.updated webhooks; this just avoids a
      # misleading stale status in the window before the first one arrives.
      refreshed = client.orders.get(order_id: square_order.id).order

      SpreePos::Orders::PushResult.new(
        external_order_id: square_order.id,
        external_payment_id: payment.id,
        external_location_id: square_order.location_id,
        external_version: refreshed.version,
        status: refreshed.state
      )
    end

    private

    def create_order(client, order)
      payload = build_payload(order)
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

    # Without a fulfillment, the order has nothing for the kitchen/POS to
    # advance through — it just sits there as a paid ticket with no
    # PROPOSED -> RESERVED -> PREPARED -> COMPLETED progression, and
    # order.fulfillment.updated never fires (confirmed: a pushed order with
    # no fulfillments produced zero fulfillment webhooks). PICKUP for now —
    # "Pay at pickup" is the only payment method configured; DELIVERY comes
    # with DoorDash Drive in phase 2.
    def build_fulfillment(order)
      {
        type: 'PICKUP',
        pickup_details: {
          recipient: {
            display_name: order.bill_address&.full_name || order.email,
            email_address: order.email,
            phone_number: order.bill_address&.phone
          }.compact,
          schedule_type: 'ASAP'
        }
      }
    end

    # Phase 3, sequence step 25: the bare, unscoped
    # StockLocation.find_by(default: true) this fallback used to be is
    # forbidden in sync/order/webhook paths -- Order#fulfilling_stock_location
    # (spree_pos, shared with SpreePos::OrderPush's own 16.2 resolution)
    # replaces it. Same behavior for every order that has a shipment
    # (the overwhelming majority); the only case that changes is an order
    # with no shipment at all, which now falls back to
    # order.preferred_stock_location -- a real, meaningful signal Spree
    # already provides -- instead of an arbitrary global default.
    def location_mapping_for(order)
      stock_location = order.fulfilling_stock_location
      return nil unless stock_location

      SpreeSquare::LocationMapping.find_by(spree_stock_location_id: stock_location.id)
    end

    def build_line_item(line_item)
      currency = (line_item.currency || 'USD').upcase
      catalog_mapping = SpreeSquare::CatalogMapping.find_by(
        spree_variant_id: line_item.variant_id,
        square_object_type: SpreeSquare::CatalogMapping::ITEM_VARIATION
      )
      modifiers = SpreeSquare::LineItemModifier.where(line_item_id: line_item.id).to_a
      modifier_total_cents = modifiers.sum(&:price_cents_snapshot)
      base_price_cents = (line_item.price * 100).round - modifier_total_cents

      # square_tax_id (the CatalogTax's own object id, already globally
      # unique within the store's catalog) doubles as the tax's `uid` here —
      # no need to mint a fresh SecureRandom uid and thread it through, since
      # every reference to the same tax across line items naturally resolves
      # to the same value.
      tax_category = line_item.variant&.product&.tax_category
      applied_taxes = resolve_square_tax_ids_for_category(tax_category).map { |square_tax_id| { tax_uid: square_tax_id } }

      {
        quantity: line_item.quantity.to_s,
        name: line_item.name,
        catalog_object_id: catalog_mapping&.square_catalog_object_id,
        base_price_money: { amount: base_price_cents, currency: currency },
        modifiers: modifiers.map { |modifier| build_modifier(modifier, currency) },
        applied_taxes: applied_taxes.presence
      }.compact
    end

    # Ad-hoc line item — no catalog_object_id, since a live-quoted delivery
    # fee (DoorDash/Uber Direct, priced per order/distance) has no fixed
    # CatalogItem in Square to reference. Skipped for a $0 shipment (Pickup)
    # so the kitchen ticket doesn't carry a pointless zero-amount line.
    #
    # shipment.tax_category comes from Spree::Shipment#tax_category
    # (selected_shipping_rate.tax_rate.tax_category) — set on all three
    # Spree::ShippingMethod records in Phase 8's setup_demo_tax, the same
    # Sales Tax category items carry, so this resolves through the identical
    # TaxCategoryMapping path as #build_line_item's own tax_category.
    def build_delivery_line_item(shipment)
      cost_cents = (shipment.cost * 100).round
      return nil if cost_cents.zero?

      currency = (shipment.currency || 'USD').upcase
      applied_taxes = resolve_square_tax_ids_for_category(shipment.tax_category).map { |square_tax_id| { tax_uid: square_tax_id } }

      {
        quantity: '1',
        name: shipment.shipping_method&.name || 'Delivery',
        base_price_money: { amount: cost_cents, currency: currency },
        applied_taxes: applied_taxes.presence
      }.compact
    end

    # SpreeSquare::LineItemModifier moved to SpreePos:: in Phase 2 step 12a
    # (rename migration 20260910000007); `square_modifier_id` was renamed to
    # `external_modifier_id` by that same migration.
    def build_modifier(modifier, currency)
      {
        catalog_object_id: modifier.external_modifier_id,
        name: modifier.name_snapshot,
        base_price_money: { amount: modifier.price_cents_snapshot, currency: currency }
      }
    end

    # `auto_applied` is deliberately NOT set here — found live against the
    # real Square Sandbox (not caught by mocked specs): Square rejects it as
    # a read-only, server-computed field on CreateOrder
    # ("order.taxes[0].auto_applied ... calculated and cannot be set by a
    # client"). It reflects whether Square itself inferred the tax from
    # catalog config, which isn't what's happening here — we explicitly
    # attach it via this `taxes` array + each line item's `applied_taxes`.
    def build_order_tax(square_tax_id)
      {
        uid: square_tax_id,
        catalog_object_id: square_tax_id,
        scope: 'LINE_ITEM'
      }
    end

    # Mirrors CatalogObjectMapper#resolve_tax_category's own path in
    # reverse: a product's (or, for a delivery fee, a shipping rate's)
    # tax_category was originally derived from a Square item's tax_ids
    # (Phase 8), so walking TaxCategoryMapping (tax_category -> tax_mapping
    # -> square_tax_id) recovers exactly the Square tax id(s) that category
    # represents. A nil tax_category (untaxed product, or a shipment whose
    # rate has none) simply gets no applied_taxes, same as today.
    #
    # Filters to TaxMapping#enabled — a disabled Square tax is soft-deleted
    # on the Spree::TaxRate side (see SpreePos::CatalogSync#sync_enabled_state!,
    # which destroys/restores the *rate*, not this TaxCategoryMapping/
    # TaxMapping join), so Spree's own Spree::TaxRate.adjust already excludes
    # it via that paranoid scope. Without this filter, a disabled tax would
    # still get sent to Square (which would auto-compute and add it into
    # total_money) even though the customer was never actually charged it by
    # Spree — inflating the EXTERNAL payment OrderPusher records above what
    # Spree collected. Found in review, before this ever reached production.
    #
    # TaxCategoryMapping/TaxMapping moved to SpreePos:: in Phase 2 step 13a
    # (rename migration 20260910000008); `square_tax_id` was renamed to
    # `external_id` by that same migration.
    def resolve_square_tax_ids_for_category(tax_category)
      return [] if tax_category.nil?

      @tax_ids_by_category_id[tax_category.id] ||=
        SpreePos::TaxCategoryMapping
        .where(tax_category: tax_category)
        .includes(:tax_mapping)
        .filter_map { |mapping| mapping.tax_mapping&.external_id if mapping.tax_mapping&.enabled }
        .uniq
    end
  end
end
