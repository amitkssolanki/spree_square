module SpreeSquare
  # Resolves a Square inventory-count payload (catalog_object_id,
  # location_id, quantity, state — the real field names
  # BatchRetrieveInventoryCounts returns) to a Spree::Variant +
  # Spree::StockLocation, then delegates the actual StockItem write to the
  # provider-neutral SpreePos::InventorySync.
  #
  # B2: the variant half of that resolution now goes through
  # SpreePos::ExternalRef, connection-scoped, NOT the legacy
  # SpreeSquare::CatalogMapping. This migration is mandatory and had to
  # land in the same change as the catalog write cutover: dual-write was
  # explicitly rejected, so from the moment CatalogSync writes only
  # ExternalRef, any variant synced afterwards has no legacy row — and
  # this reader would have silently stopped applying its counts
  # (`return unless mapping&.variant` fails closed and says nothing).
  #
  # The LOCATION half still uses SpreeSquare::LocationMapping. That is a
  # different table with its own migration story (spree_pos_locations) and
  # is deliberately out of B2's scope.
  class InventoryAdapter
    def self.call(...) = new.call(...)
    def self.reconcile_all!(...) = new.reconcile_all!(...)

    # `connection:` is supplied by SpreeSquare::Provider#inventory, which
    # is built with the connection the caller resolved. When it is absent
    # the connection is derived from the count's own location instead
    # (see #resolve_connection) — the inventory webhook path has no
    # connection on the event yet (plan Phase 5 / 15.2).
    def initialize(connection: nil)
      @connection = connection
    end

    # Full inventory pass for the nightly reconciliation, moved here from
    # SpreePos::ReconciliationJob#reconcile_inventory verbatim (Package A):
    # the `SpreeSquare::Client` call and the `SpreeSquare::LocationMapping`
    # lookup are both Square-specific and had no business living in
    # provider-neutral code. The job now reaches this as
    # `provider.inventory.reconcile_all!`.
    #
    # The `states:`-filter omission below is deliberate and is preserved
    # exactly: an item that went out of stock is precisely the drift this
    # pass exists to catch, and it would not appear in an IN_STOCK-only
    # result.
    # Square's own webhook payload shape, which is why it lives here and not
    # in SpreePos::InventoryWebhookJob. The job used to dig
    # `data.object.inventory_counts` out of the event itself, which worked for
    # Square and silently yielded nothing for every other provider.
    #
    # `state` maps to the neutral DTO's `in_stock` field, which is what
    # #call's `state:` argument reads; the wording differs, the value does
    # not.
    #
    # @param event [SpreePos::WebhookEvent]
    # @return [Array<SpreePos::Catalog::InventoryCount>]
    def counts_from_event(event)
      Array(event.payload.dig('data', 'object', 'inventory_counts')).map do |count|
        SpreePos::Catalog::InventoryCount.new(
          external_variant_id: count['catalog_object_id'],
          external_location_id: count['location_id'],
          quantity: count['quantity'],
          in_stock: count['state']
        )
      end
    end

    # Only this connection's own locations, read with this connection's own
    # credential. It used to pluck EVERY mapped Square location in the
    # database and read them with the default store's token.
    def reconcile_all!
      raise SpreePos::PermanentError, 'Square inventory reconciliation needs a connection' if @connection.nil?

      stock_location_ids = SpreePos::Location.where(pos_connection_id: @connection.id).select(:spree_stock_location_id)
      location_ids = SpreeSquare::LocationMapping.where(spree_stock_location_id: stock_location_ids).pluck(:square_location_id)
      return if location_ids.empty?

      SpreeSquare::Client.for_connection(@connection).inventory.batch_get_counts(location_ids: location_ids).each do |count|
        call(
          catalog_object_id: count.catalog_object_id,
          location_id: count.location_id,
          quantity: count.quantity,
          state: count.state
        )
      end
    end

    # Order of resolution changed in B2 (location first, then variant),
    # because the location is what identifies the connection the variant
    # ref must be scoped to. The net effect is unchanged: both must
    # resolve or nothing is written.
    def call(catalog_object_id:, location_id:, quantity:, state: 'IN_STOCK')
      location_mapping = SpreeSquare::LocationMapping.find_by(square_location_id: location_id)
      return unless location_mapping

      connection = resolve_connection(location_mapping)
      # A count for a location owned by a DIFFERENT connection than the one
      # this adapter acts for is not ours to apply, whatever the payload says:
      # writing it would change another store's stock.
      if @connection && !location_owned_by?(location_mapping, @connection)
        Rails.logger.warn(
          "[SpreeSquare] inventory count for location #{location_id.inspect} does not belong to connection " \
          "#{@connection.id} - skipping."
        )
        return
      end
      # Distinct from the two ordinary misses below, which are silent by
      # design (an unmapped location or an unsynced item is a normal,
      # expected state). A location that IS mapped but resolves to no POS
      # connection is a misconfiguration, so it is logged rather than
      # swallowed — B2 must not silently broaden the set of quiet misses.
      if connection.nil?
        Rails.logger.warn(
          "[SpreeSquare] inventory count for location #{location_id.inspect} could not be attributed to a " \
          'SpreePos::Connection — skipping. The stock location is mapped but has no POS connection.'
        )
        return
      end

      ref = SpreePos::ExternalRef
            .for_connection(connection)
            .of_type(SpreePos::ExternalRef::RESOURCE_VARIATION)
            .find_by(external_id: catalog_object_id)
      return unless ref&.variant

      SpreePos::InventorySync.call(
        variant: ref.variant,
        stock_location: location_mapping.stock_location,
        quantity: quantity,
        state: state
      )
    end

    private

    # The connection supplied by the provider, else the one that owns this
    # physical location. Never a global or default lookup: an inventory
    # count belongs to exactly one location, and that location belongs to
    # exactly one POS connection.
    def location_owned_by?(location_mapping, connection)
      SpreePos::Location.exists?(spree_stock_location_id: location_mapping.spree_stock_location_id,
                                 pos_connection_id: connection.id)
    end

    def resolve_connection(location_mapping)
      @connection || SpreePos::Location.find_by(stock_location: location_mapping.stock_location)&.pos_connection
    end
  end
end
