module Spree
  # Zeitwerk requires this module's name to match its file path exactly
  # (app/models/spree/line_item_decorator.rb -> Spree::LineItemDecorator) —
  # under dev's lazy autoloading, a mismatched name (e.g. a
  # SpreeSquare-prefixed one) means nothing ever triggers loading this file
  # at all, silently, since nothing references the name Zeitwerk expects.
  module LineItemDecorator
    # Transient carrier for selected modifier ids from add-to-cart through to
    # SpreeSquare::Cart::AddItem, which reads it right after `super` to build
    # the persistent LineItemModifier snapshot rows. Never persisted itself —
    # `square_modifier_ids=` is populated via LineItem#options= (see
    # `variant_decorator.rb`'s `square_modifier_ids_price_modifier_amount`,
    # dispatched from the same options hash), which only lives for the
    # request that created the line item.
    attr_accessor :square_modifier_ids

    # Both of these reset price to the variant's base price with no idea
    # about our modifier selections (which live in a separate table
    # specifically so a later Square catalog edit can't retroactively change
    # what a customer already paid for) — necessary so a genuine price
    # change from Square (M3) takes effect, but it means the modifier delta
    # has to be re-added every time, not just once at add-to-cart.
    #
    # Confirmed (by grepping all of spree_core, not sampling) these are the
    # *only* two places core reassigns line item price outside our own code:
    # `recalculate_price` fires on cart mutations (Cart::AddItem calls it
    # directly); `update_price` is what Order#update_line_item_prices! calls
    # on every line item via a `before_transition from: :address` checkout
    # callback — the bug that surfaced this: modifier pricing was correct
    # right after add-to-cart, then silently reverted to base price the
    # moment checkout address was submitted.
    def recalculate_price
      super
      apply_square_modifier_delta!
    end

    def update_price
      super
      apply_square_modifier_delta!
    end

    private

    def apply_square_modifier_delta!
      return unless persisted?

      delta_cents = SpreeSquare::LineItemModifier.where(line_item_id: id).sum(:price_cents_snapshot)
      return if delta_cents.zero?

      update_columns(price: price + (delta_cents / 100.0), updated_at: Time.current)
    end
  end

  LineItem.prepend(LineItemDecorator)
end
