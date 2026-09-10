module SpreeSquare
  # RETAINED COMPATIBILITY FACADE.
  #
  # `SpreePos::CatalogSync` accepts only provider-neutral
  # `SpreePos::Catalog::*` DTOs as of B3. This class keeps the older
  # "hand me one raw Square catalog object" API alive for the callers that
  # still use it, by converting each object through
  # `SpreeSquare::CatalogAdapter`'s own DTO builders and delegating.
  #
  # It is kept for two concrete reasons, not out of caution:
  #
  #   1. `spec/services/spree_square/order_adapter_spec.rb` builds a real
  #      Spree::TaxCategory by calling `mapper.map_tax` / `mapper.map_item`
  #      with raw Square objects, as fixture setup for order-push assertions
  #      that have nothing to do with catalog sync. Rewriting those onto
  #      DTOs would be an unrelated change to order-push coverage.
  #   2. `catalog_object_mapper_spec.rb` / `catalog_object_mapper_tax_spec.rb`
  #      are the characterization suite for the catalog behaviour B3 had to
  #      preserve exactly. Keeping them pointed at the same raw-object API
  #      they were written against is precisely what makes them evidence
  #      that behaviour did not change — rewriting the tests and the code
  #      in the same step would prove nothing.
  #
  # Living in the Square gem, it is allowed to know it is Square. It holds
  # no mapping logic of its own; every method is convert-then-delegate.
  #
  # Retire it by moving those callers onto DTOs directly; nothing in
  # spree_pos depends on it.
  class CatalogObjectMapper
    VARIATION_OPTION_TYPE_NAME = SpreePos::CatalogSync::VARIATION_OPTION_TYPE_NAME

    def initialize(related_objects_by_id: {})
      @related_objects_by_id = related_objects_by_id
      # No credential is resolved by this construction — CatalogAdapter's
      # client is lazy precisely so DTO conversion stays free.
      @adapter = SpreeSquare::CatalogAdapter.new
      @sync = SpreePos::CatalogSync.new
    end

    def map_category(square_object)
      @sync.map_category(@adapter.category_dto(square_object))
    end

    def map_tax(square_object)
      @sync.map_tax(@adapter.tax_dto(square_object))
    end

    def map_item(square_object)
      @sync.map_item(@adapter.item_dto(square_object, @related_objects_by_id))
    end

    def map_variation(square_object, product)
      @sync.map_variation(@adapter.variation_dto(square_object), product)
    end

    def map_modifier_list(square_object)
      @sync.map_modifier_list(@adapter.modifier_group_dto(square_object))
    end

    def map_modifier(square_object, modifier_list)
      @sync.map_modifier(@adapter.modifier_dto(square_object), modifier_list)
    end

    # Delegates everything else (the private methods some characterization
    # specs reach via `mapper.send(:composite_tax_category, ...)`, etc.) to
    # the real implementation.
    def method_missing(name, ...)
      if @sync.respond_to?(name, true)
        @sync.send(name, ...)
      else
        super
      end
    end

    def respond_to_missing?(name, include_private = false)
      @sync.respond_to?(name, true) || super
    end
  end
end
