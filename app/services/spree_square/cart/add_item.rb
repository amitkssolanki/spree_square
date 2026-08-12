module SpreeSquare
  module Cart
    # Mirrors Spree::Cart::AddItem's own step sequence (see CLAUDE.md pattern
    # #2 — swap the service, don't decorate it) with one inserted step.
    #
    # Selected modifier ids arrive via the line item's transient
    # `square_modifier_ids` (set by LineItem#options=, populated from the
    # `options:` param — see variant_decorator.rb's dispatch target and the
    # `Spree::PermittedAttributes.line_item_attributes` addition in this
    # extension's initializer). That gets the *initial* price right via
    # Spree's own price-modifier mechanism, but the persistent
    # LineItemModifier snapshot rows — what survives future recalculations
    # and what M5's order push reads — don't exist until this step creates
    # them. `add_to_line_item` already called `recalculate_price` once
    # (before these rows existed, so it found no delta); calling it again
    # here is what makes the response actually reflect the final price.
    class AddItem < Spree::Cart::AddItem
      # Spree::ServiceModule::Base is prepended onto the *parent* class
      # (Spree::Cart::AddItem). A subclass's own `call` sits ahead of that
      # prepended module in ITS OWN ancestor chain (subclassing doesn't lower
      # the subclass's method priority below modules prepended only onto the
      # ancestor) — without re-prepending here, `run` blows up on a nil
      # `@_passed_input` because Base#call never got a chance to initialize it.
      prepend Spree::ServiceModule::Base

      def call(order:, variant:, quantity: nil, metadata: {}, public_metadata: {}, private_metadata: {}, options: {})
        ApplicationRecord.transaction do
          run :add_to_line_item
          run :attach_square_modifiers
          run :handle_stock_reservations
          run Spree.cart_recalculate_service
        end
      end

      private

      def attach_square_modifiers(order:, line_item:, line_item_created:, options:)
        modifier_ids = Array(line_item.square_modifier_ids)

        if modifier_ids.present? && line_item_created
          SpreeSquare::Modifier.where(square_modifier_id: modifier_ids).find_each do |modifier|
            lim = SpreeSquare::LineItemModifier.build_from(modifier)
            lim.line_item = line_item
            lim.save!
          end
          line_item.recalculate_price
        end

        success(order: order, line_item: line_item, line_item_created: line_item_created, options: options)
      end
    end
  end
end
