module SpreeSquare
  # Resolves a Square inventory-count payload (catalog_object_id,
  # location_id, quantity, state — the real field names
  # BatchRetrieveInventoryCounts returns) to a Spree::Variant +
  # Spree::StockLocation via the existing CatalogMapping/LocationMapping
  # tables, then delegates the actual StockItem write to the
  # provider-neutral SpreePos::InventorySync.
  #
  # This mapping-table lookup is deliberately left untouched here (see plan
  # section 9.3 and 14.4/17.2): those tables are pure id-pair mappings slated
  # to fold into SpreePos::ExternalRef / SpreePos::Location, but that is a
  # real data migration reserved for a later phase. Nothing has ever
  # populated ExternalRef/SpreePos::Location, so switching this lookup over
  # now would silently break inventory sync. This class keeps today's
  # resolution logic verbatim; only the class it delegates to changed.
  class InventoryAdapter
    def self.call(...) = new.call(...)

    def call(catalog_object_id:, location_id:, quantity:, state: 'IN_STOCK')
      mapping = SpreeSquare::CatalogMapping.find_by(
        square_catalog_object_id: catalog_object_id,
        square_object_type: SpreeSquare::CatalogMapping::ITEM_VARIATION
      )
      return unless mapping&.variant

      location_mapping = SpreeSquare::LocationMapping.find_by(square_location_id: location_id)
      return unless location_mapping

      SpreePos::InventorySync.call(
        variant: mapping.variant,
        stock_location: location_mapping.stock_location,
        quantity: quantity,
        state: state
      )
    end
  end
end
