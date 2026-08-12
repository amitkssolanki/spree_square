module Spree
  # Zeitwerk-compliant name required for this file to autoload at all — see
  # the comment in line_item_decorator.rb.
  module VariantDecorator
    # Hooks into Spree's own pluggable price-modifier dispatch
    # (Variant#price_modifier_amount calls "#{key}_price_modifier_amount" for
    # each key present in the line item's `options`) so the *initial*
    # add-to-cart price is correct immediately, before LineItemModifier rows
    # even exist yet. The decorated LineItem#recalculate_price is what keeps
    # it correct after that.
    def square_modifier_ids_price_modifier_amount(modifier_ids)
      return 0 if modifier_ids.blank?

      SpreeSquare::Modifier.where(square_modifier_id: Array(modifier_ids)).sum(:price_cents) / 100.0
    end
  end

  Variant.prepend(VariantDecorator)
end
