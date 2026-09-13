module Spree
  module Admin
    # Read-only support/diagnostic view — no create/edit/destroy, this is
    # visibility into what Square's own tax config has synced into Spree,
    # not a place to change it (edits happen in Square's own dashboard).
    # Mirrors SquareOrderMappingsController exactly.
    class SquareTaxRatesController < ResourceController
      def model_class
        Spree::TaxRate
      end

      private

      # `scope`, not `collection` — collection is ResourceController's full
      # ransack+pagination pipeline (search_collection.result...pagy), and
      # overriding it directly skips building @search, which is exactly
      # what `render_table`'s search_form_for needs. `scope` is the one
      # documented extension point for narrowing the base query before
      # ransack/pagination run. Scoped here so this page only ever shows
      # rates this extension actually created (via
      # SpreePos::TaxCategoryMapping, moved from SpreeSquare::
      # TaxCategoryMapping in Phase 2 step 13a), not any rate a store admin
      # might separately hand-create in the regular Spree tax-rates admin
      # page.
      def scope
        # Only rates synced from this store's own POS connections. Spree::TaxRate
        # is global, so the unscoped version listed every store's POS taxes.
        connection_ids = SpreePos::Connection.where(store_id: current_store.id).select(:id)
        mapping_ids = SpreePos::TaxMapping.where(pos_connection_id: connection_ids).select(:id)
        Spree::TaxRate.where(id: SpreePos::TaxCategoryMapping.where(tax_mapping_id: mapping_ids).select(:tax_rate_id))
      end
    end
  end
end
