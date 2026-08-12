module SpreeSquare
  # Builds the Square CreateOrder payload for a completed Spree::Order.
  # Deliberately omits pricing beyond per-line-item base_price_money/modifiers
  # — no taxes/discounts sent — so Square's computed total_money is exactly
  # what OrderPusher then charges via the EXTERNAL payment, with nothing for
  # Square's own tax/discount engine to add on top and create a mismatch.
  class OrderBuilder
    def self.call(...) = new.call(...)

    def call(order)
      location_mapping = location_mapping_for(order)
      raise "No Square location mapped for order #{order.number}" unless location_mapping

      {
        location_id: location_mapping.square_location_id,
        reference_id: order.number,
        line_items: order.line_items.map { |line_item| build_line_item(line_item) },
        fulfillments: [build_fulfillment(order)]
      }
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

      {
        quantity: line_item.quantity.to_s,
        name: line_item.name,
        catalog_object_id: catalog_mapping&.square_catalog_object_id,
        base_price_money: { amount: base_price_cents, currency: currency },
        modifiers: modifiers.map { |modifier| build_modifier(modifier, currency) }
      }.compact
    end

    def build_modifier(modifier, currency)
      {
        catalog_object_id: modifier.square_modifier_id,
        name: modifier.name_snapshot,
        base_price_money: { amount: modifier.price_cents_snapshot, currency: currency }
      }
    end
  end
end
