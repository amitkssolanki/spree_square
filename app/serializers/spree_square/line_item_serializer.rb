module SpreeSquare
  # Exposes the modifiers selected on a line item (for cart/checkout
  # display) using the snapshot recorded at add-to-cart time — never a live
  # lookup, so a later Square menu edit can't change what's shown for an
  # existing cart/order.
  class LineItemSerializer < Spree::Api::V3::LineItemSerializer
    attribute :square_modifiers do |line_item|
      SpreeSquare::LineItemModifier.where(line_item_id: line_item.id).map do |lim|
        { name: lim.name_snapshot, price_cents: lim.price_cents_snapshot, display_price: lim.price_cents_snapshot / 100.0 }
      end
    end
  end
end
