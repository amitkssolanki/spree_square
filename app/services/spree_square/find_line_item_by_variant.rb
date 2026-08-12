module SpreeSquare
  # Spree::LineItems::FindByVariant matches purely on variant_id — it calls
  # Spree.cart_compare_line_items_service but discards the result without
  # using it to gate anything, so customizing that comparator alone has no
  # effect (verified directly: swapping just the comparator did not stop two
  # differently-modified line items from merging). This finder replaces the
  # matching logic itself, so "Margherita Pizza + extra cheese" and
  # "Margherita Pizza + no cheese" land in separate line items instead of
  # silently merging into one with the first selection's modifiers.
  class FindLineItemByVariant
    def execute(order:, variant:, options: {})
      requested = Array(options[:square_modifier_ids] || options['square_modifier_ids']).sort

      order.line_items.where(variant_id: variant.id).detect do |line_item|
        existing = SpreeSquare::LineItemModifier.where(line_item_id: line_item.id)
                                                 .pluck(:square_modifier_id).compact.sort
        existing == requested
      end
    end
  end
end
