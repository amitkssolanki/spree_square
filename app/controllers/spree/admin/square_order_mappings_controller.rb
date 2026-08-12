module Spree
  module Admin
    # Read-only support/diagnostic view — no create/edit/destroy, this is
    # visibility into what spree_square has already done, not a place to
    # change it. See config/routes.rb (only: [:index]).
    class SquareOrderMappingsController < ResourceController
      def model_class
        SpreeSquare::OrderMapping
      end
    end
  end
end
