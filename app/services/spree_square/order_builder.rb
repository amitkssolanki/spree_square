module SpreeSquare
  # Builds the Square CreateOrder payload for a completed Spree::Order.
  # Deliberately omits pricing beyond per-line-item base_price_money/modifiers
  # and shipping/delivery fees — so Square's computed total_money is exactly
  # what OrderPusher then charges via the EXTERNAL payment, with nothing for
  # Square's own discount engine to add on top and create a mismatch. Item
  # sales tax IS sent (see #build_line_item/#resolve_square_tax_mappings) —
  # Square requires an explicit order-level `taxes` array plus a per-line-item
  # `applied_taxes` reference; simply pointing a line item's catalog_object_id
  # at a taxed CatalogItem does NOT make Square auto-compute tax on it, which
  # is why every order pushed before this fix showed $0 tax and an
  # EXTERNAL-payment total matching item price alone (found live, comparing a
  # real order confirmation against its Square receipt: Spree charged $19.42
  # with $1.44 tax, Square's own ticket/payment showed a bare $9.99).
  class OrderBuilder
    def self.call(...) = new.call(...)

    def call(order)
      location_mapping = location_mapping_for(order)
      raise "No Square location mapped for order #{order.number}" unless location_mapping

      tax_uids_by_square_tax_id = {}
      built_line_items = order.line_items.map { |line_item| build_line_item(line_item, tax_uids_by_square_tax_id) }

      {
        location_id: location_mapping.square_location_id,
        reference_id: order.number,
        line_items: built_line_items,
        taxes: tax_uids_by_square_tax_id.map { |square_tax_id, uid| build_order_tax(square_tax_id, uid) }.presence,
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

    def build_line_item(line_item, tax_uids_by_square_tax_id)
      currency = (line_item.currency || 'USD').upcase
      catalog_mapping = SpreeSquare::CatalogMapping.find_by(
        spree_variant_id: line_item.variant_id,
        square_object_type: SpreeSquare::CatalogMapping::ITEM_VARIATION
      )
      modifiers = SpreeSquare::LineItemModifier.where(line_item_id: line_item.id).to_a
      modifier_total_cents = modifiers.sum(&:price_cents_snapshot)
      base_price_cents = (line_item.price * 100).round - modifier_total_cents

      applied_taxes = resolve_square_tax_ids(line_item).map do |square_tax_id|
        uid = (tax_uids_by_square_tax_id[square_tax_id] ||= SecureRandom.uuid)
        { tax_uid: uid }
      end

      {
        quantity: line_item.quantity.to_s,
        name: line_item.name,
        catalog_object_id: catalog_mapping&.square_catalog_object_id,
        base_price_money: { amount: base_price_cents, currency: currency },
        modifiers: modifiers.map { |modifier| build_modifier(modifier, currency) },
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

    def build_order_tax(square_tax_id, uid)
      {
        uid: uid,
        catalog_object_id: square_tax_id,
        scope: 'LINE_ITEM',
        auto_applied: true
      }
    end

    # Mirrors CatalogObjectMapper#resolve_tax_category's own path in
    # reverse: a product's tax_category was originally derived from its
    # Square item's tax_ids (Phase 8), so walking
    # TaxCategoryMapping (tax_category -> tax_mapping -> square_tax_id)
    # recovers exactly the Square tax id(s) that category represents.
    # Non-taxable products (no tax_category, or a category with no
    # TaxCategoryMapping rows — e.g. modifiers-only pricing quirks) simply
    # get no applied_taxes, same as today.
    def resolve_square_tax_ids(line_item)
      tax_category = line_item.variant&.product&.tax_category
      return [] if tax_category.nil?

      SpreeSquare::TaxCategoryMapping
        .where(tax_category: tax_category)
        .includes(:tax_mapping)
        .filter_map { |mapping| mapping.tax_mapping&.square_tax_id }
        .uniq
    end
  end
end
