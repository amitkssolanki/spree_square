module SpreeSquare
  # Applies a single Square inventory count to the matching Spree::StockItem.
  # No backordering food: backorderable is always forced false regardless of
  # what it was set to before.
  class InventorySync
    def self.call(...) = new.call(...)

    def call(catalog_object_id:, location_id:, quantity:, state: 'IN_STOCK')
      mapping = SpreeSquare::CatalogMapping.find_by(
        square_catalog_object_id: catalog_object_id,
        square_object_type: SpreeSquare::CatalogMapping::ITEM_VARIATION
      )
      return unless mapping&.variant

      location_mapping = SpreeSquare::LocationMapping.find_by(square_location_id: location_id)
      return unless location_mapping

      stock_item = location_mapping.stock_location.stock_item_or_create(mapping.variant)
      stock_item.backorderable = false
      stock_item.set_count_on_hand(state == 'IN_STOCK' ? quantity.to_i : 0)

      # Stock changes touch product without firing product.updated (see
      # Revalidator) — the storefront's "in stock"/"add to cart" state needs
      # telling explicitly.
      product = mapping.variant.product
      SpreeSquare::Revalidator.call(['products', "product:#{product.slug}"])
    end
  end
end
