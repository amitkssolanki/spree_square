module SpreeSquare
  # Deprecated facade. Phase 2 (step 13 of the multi-POS/multi-location plan)
  # extracted this class's tax/product/variant/category mapping logic
  # verbatim into SpreePos::CatalogSync — see that file for the real
  # implementation and its comments (all preserved unchanged).
  #
  # Kept here, thin, for two reasons:
  #
  # 1. Backward compatibility with code outside this worker's stated scope
  #    that still references `SpreeSquare::CatalogObjectMapper` by name:
  #    `app/services/spree_square/order_builder.rb` and its spec build a
  #    tax_category through `mapper.map_tax` / `mapper.map_item` directly
  #    (see order_builder_spec.rb, "a line item whose product carries a
  #    synced Square tax"). Rule 5 of this worker's brief forbids touching
  #    order push (Phase 2D, step 16) — deleting this class outright would
  #    have broken that already-passing spec as a side effect of an
  #    unrelated rename, not something a "no behaviour change" phase should
  #    do.
  #
  # 2. `map_modifier_list` / `map_modifier` did NOT move in this batch (see
  #    SpreePos::CatalogSync's own class comment) — they're real,
  #    unchanged implementations living on this class, not delegated.
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

    # --- Not moved in Phase 2 step 13 (out of scope for this worker; see
    # SpreePos::CatalogSync's class comment for why) — real, unchanged
    # implementations, exactly as before the extraction. ---

    # A Square MODIFIER_LIST embeds its full MODIFIER objects inline (same
    # pattern as ITEM#variations) — no follow-up API call needed.
    #
    # square_modifier_list_id/square_modifier_id/square_version were renamed
    # to external_id/external_id/external_version by the Phase 2 step 12a
    # rename migration (20260910000007) — repointed here so this still-live
    # code path (called for real by CatalogImporter#call, not just exercised
    # through a mock) keeps working, not just its mocked characterization
    # spec.
    def map_modifier_list(square_object)
      data = square_object.modifier_list_data
      list = SpreeSquare::ModifierList.find_or_initialize_by(external_id: square_object.id)
      list.name = data.name.presence || 'Options'
      list.selection_type = data.selection_type.presence || SpreeSquare::ModifierList::SINGLE
      list.min_selected_modifiers = data.min_selected_modifiers
      list.max_selected_modifiers = data.max_selected_modifiers
      list.external_version = square_object.version
      list.save!

      Array(data.modifiers).each { |modifier| map_modifier(modifier, list) }
      list
    end

    def map_modifier(square_object, modifier_list)
      data = square_object.modifier_data
      modifier = SpreeSquare::Modifier.find_or_initialize_by(external_id: square_object.id)
      modifier.modifier_list = modifier_list
      modifier.name = data.name.presence || 'Option'
      modifier.price_cents = data.price_money&.amount || 0
      modifier.external_version = square_object.version
      modifier.save!
      modifier
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
