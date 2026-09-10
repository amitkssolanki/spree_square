module SpreeSquare
  # Deprecated facade. Phase 2 (step 13 of the multi-POS/multi-location plan)
  # extracted this class's tax/product/variant/category mapping logic
  # verbatim into SpreePos::CatalogSync — see that file for the real
  # implementation and its comments (all preserved unchanged).
  #
  # Kept here, thin, for one reason: backward compatibility with code
  # outside this worker's stated scope that still references
  # `SpreeSquare::CatalogObjectMapper` by name:
  # `app/services/spree_square/order_builder.rb` and its spec build a
  # tax_category through `mapper.map_tax` / `mapper.map_item` directly
  # (see order_builder_spec.rb, "a line item whose product carries a
  # synced Square tax"). Rule 5 of this worker's brief forbids touching
  # order push (Phase 2D, step 16) — deleting this class outright would
  # have broken that already-passing spec as a side effect of an
  # unrelated rename, not something a "no behaviour change" phase should
  # do.
  #
  # `map_modifier_list` / `map_modifier` did NOT move to SpreePos::CatalogSync
  # in Phase 2 (see that class's own comment history) but DO now, as of
  # Phase 3 (this session): Phase 3's tighten migration made
  # spree_pos_modifier_lists/modifiers.pos_connection_id NOT NULL, and
  # SpreePos::CatalogSync's own @connection (self-resolved from the store's
  # one real catalog-source SpreePos::Connection) is the only correct,
  # single-sourced place to get one from — so these two are thin delegates
  # now too, exactly like every other map_* method here.
  #
  # Remove this shim once order push (step 16) also migrates off
  # SpreeSquare::CatalogObjectMapper.
  class CatalogObjectMapper
    VARIATION_OPTION_TYPE_NAME = SpreePos::CatalogSync::VARIATION_OPTION_TYPE_NAME

    def initialize(related_objects_by_id: {})
      @related_objects_by_id = related_objects_by_id
      @sync = SpreePos::CatalogSync.new(related_objects_by_id: related_objects_by_id)
    end

    def map_category(square_object) = @sync.map_category(square_object)
    def map_tax(square_object) = @sync.map_tax(square_object)
    def map_item(square_object) = @sync.map_item(square_object)
    def map_variation(square_object, product) = @sync.map_variation(square_object, product)
    def map_modifier_list(square_object) = @sync.map_modifier_list(square_object)
    def map_modifier(square_object, modifier_list) = @sync.map_modifier(square_object, modifier_list)

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
