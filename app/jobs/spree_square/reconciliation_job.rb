module SpreeSquare
  # Nightly safety net for missed or failed webhooks — re-runs the same
  # catalog import and inventory sync services M2/M3 already built (no new
  # sync logic), just as a full pass instead of an incremental one. Cheap
  # insurance for a restaurant-sized catalog; not built for a bulk catalog.
  class ReconciliationJob < BaseJob
    retry_on StandardError, wait: :polynomially_longer, attempts: 3 do |_job, error|
        SpreeSquare::Alerting.capture(error, context: 'reconciliation')
    end

    def perform
      SpreeSquare::CatalogImporter.call
      reconcile_inventory
    end

    private

    def reconcile_inventory
      client = SpreeSquare::Client.instance
      location_ids = SpreeSquare::LocationMapping.pluck(:square_location_id)
      return if location_ids.empty?

      # No `states:` filter — an item that went out of stock is exactly the
      # kind of drift this job exists to catch, and it wouldn't show up in
      # an IN_STOCK-only result.
      client.inventory.batch_get_counts(location_ids: location_ids).each do |count|
        SpreeSquare::InventorySync.call(
          catalog_object_id: count.catalog_object_id,
          location_id: count.location_id,
          quantity: count.quantity,
          state: count.state
        )
      end
    end
  end
end
