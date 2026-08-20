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
      # SpreeSquare::TaxCategoryMapping), not any rate a store admin might
      # separately hand-create in the regular Spree tax-rates admin page.
      def scope
        Spree::TaxRate.where(id: SpreeSquare::TaxCategoryMapping.select(:tax_rate_id))
      end
    end
  end
end
