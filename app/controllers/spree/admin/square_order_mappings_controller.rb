module Spree
  module Admin
    # Read-only support/diagnostic view — no create/edit/destroy, this is
    # visibility into what spree_square has already done, not a place to
    # change it. See config/routes.rb (only: [:index]).
    #
    # Repointed at SpreePos::OrderMapping (Agent D1's model, moved wholesale
    # from SpreeSquare::OrderMapping) — same route/URL, same precedent as
    # SquareTaxRatesController's own repoint at SpreePos::TaxCategoryMapping.
    class SquareOrderMappingsController < ResourceController
      def model_class
        SpreePos::OrderMapping
      end
    end
  end
end
