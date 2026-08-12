module SpreeSquare
  # Adds the modifier lists attached to a product (see
  # customization/api.mdx's documented pattern: subclass the core V3
  # serializer and register via Spree::Api::Dependencies, rather than
  # decorating Spree::Api::V3::ProductSerializer directly).
  class ProductSerializer < Spree::Api::V3::ProductSerializer
    # Re-declares the `categories` field from the core serializer (Alba
    # associations are keyed by name, so redeclaring here overrides it) to
    # fix a NoMethodError on `Spree::Category` taxons.
    #
    # The core field is `taxons.select { |t| t.taxonomy.store_id == ... }`,
    # which assumes every taxon belongs to a Taxonomy. `Spree::Category` (see
    # its own comment: the store-scoped, taxonomy-free replacement — becomes
    # the base class in Spree 6.0) has `taxonomy_id: nil`, so `t.taxonomy` is
    # nil and `.store_id` raises. Any `expand=categories` (or
    # `categories.ancestors`, as the Next.js storefront's PDP always
    # requests) 500s for every product in this catalog, since it's entirely
    # Category-based. A Category is already store-scoped via its own
    # `store_id` column (no taxonomy indirection needed), so that's the
    # correct check to fall back to when `taxonomy` is nil.
    many :taxons,
         proc { |taxons, params|
           taxons.select { |t| (t.taxonomy&.store_id || t.store_id) == params[:store].id }
         },
         key: :categories,
         resource: proc { Spree.api.category_serializer },
         if: proc { expand?('categories') }

    attribute :modifier_lists do |product|
      SpreeSquare::ProductModifierList.where(product_id: product.id)
                                       .includes(modifier_list: :modifiers)
                                       .map do |pml|
        list = pml.modifier_list
        {
          id: list.square_modifier_list_id,
          name: list.name,
          selection_type: list.selection_type,
          min_selected_modifiers: list.min_selected_modifiers,
          max_selected_modifiers: list.max_selected_modifiers,
          modifiers: list.modifiers.map do |m|
            { id: m.square_modifier_id, name: m.name, price_cents: m.price_cents, display_price: m.price }
          end
        }
      end
    end
  end
end
