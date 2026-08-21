module SpreeSquare
  # Builds the Square CreateOrder payload for a completed Spree::Order.
  # Deliberately omits discounts — nothing for Square's own discount engine
  # to add on top of what we send and create a mismatch. Everything Square
  # actually charges (items, modifiers, delivery fee, tax) is now sent
  # explicitly, so `total_money` in the create-order response is fully
  # derived from this payload — never independently computed by Square —
  # which is what lets OrderPusher trust it as the EXTERNAL payment amount.
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
  class OrderBuilder
    def self.call(...) = new.call(...)

    def call(order)
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

    private

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

    def location_mapping_for(order)
      stock_location = order.shipments.first&.stock_location || Spree::StockLocation.find_by(default: true)
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

    def build_modifier(modifier, currency)
      {
        catalog_object_id: modifier.square_modifier_id,
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
    # on the Spree::TaxRate side (see CatalogObjectMapper#sync_enabled_state!,
    # which destroys/restores the *rate*, not this TaxCategoryMapping/
    # TaxMapping join), so Spree's own Spree::TaxRate.adjust already excludes
    # it via that paranoid scope. Without this filter, a disabled tax would
    # still get sent to Square (which would auto-compute and add it into
    # total_money) even though the customer was never actually charged it by
    # Spree — inflating the EXTERNAL payment OrderPusher records above what
    # Spree collected. Found in review, before this ever reached production.
    def resolve_square_tax_ids_for_category(tax_category)
      return [] if tax_category.nil?

      @tax_ids_by_category_id[tax_category.id] ||=
        SpreeSquare::TaxCategoryMapping
        .where(tax_category: tax_category)
        .includes(:tax_mapping)
        .filter_map { |mapping| mapping.tax_mapping&.square_tax_id if mapping.tax_mapping&.enabled }
        .uniq
    end
  end
end
