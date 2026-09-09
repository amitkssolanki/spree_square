module SpreeSquare
  # Phase 2, step 14 of the multi-POS/multi-location plan: the
  # Square-API-specific half of what used to be
  # `SpreeSquare::CatalogImporter#fetch_all` — paginating
  # `catalog.search`, inlining related objects (images, referenced
  # categories), and grouping the results by type. `CatalogImporter`
  # becomes the thin job wrapper; this class owns "how do we talk to
  # Square."
  class CatalogAdapter
    FetchResult = Struct.new(:categories, :modifier_lists, :taxes, :items, :related_objects_by_id, keyword_init: true)

    def initialize(client: SpreeSquare::Client.instance)
      @client = client
    end

    # Square's search is a single page per call; loop on `cursor` until
    # exhausted. Fine for a restaurant-sized catalog (dozens to low hundreds
    # of items) — not built for bulk/enterprise catalogs. (Moved verbatim
    # from CatalogImporter#fetch_all.)
    def fetch_all
      objects = []
      related_by_id = {}
      cursor = nil

      loop do
        response = @client.catalog.search(
          object_types: %w[ITEM CATEGORY MODIFIER_LIST TAX],
          include_related_objects: true,
          cursor: cursor
        )

        objects.concat(Array(response.objects))
        Array(response.related_objects).each { |o| related_by_id[o.id] = o }

        cursor = response.cursor
        break if cursor.blank?
      end

      by_type = objects.group_by(&:type)
      FetchResult.new(
        categories: by_type.fetch('CATEGORY', []),
        modifier_lists: by_type.fetch('MODIFIER_LIST', []),
        taxes: by_type.fetch('TAX', []),
        items: by_type.fetch('ITEM', []),
        related_objects_by_id: related_by_id
      )
    end

    # Translates a #fetch_all result into the provider-neutral
    # SpreePos::Catalog DTOs defined in Phase 1
    # (spree_pos/app/services/spree_pos/catalog/{item,variation,category,
    # tax,modifier,modifier_group,snapshot}.rb).
    #
    # NOT yet wired into the live catalog-sync path (see CatalogImporter,
    # which calls #fetch_all and feeds its raw, ungrouped-by-DTO objects to
    # SpreeSquare::CatalogObjectMapper / SpreePos::CatalogSync directly) —
    # deliberately, and flagged to the lead rather than silently decided:
    # none of the Phase 1 Catalog DTOs (Category/Tax/Item/Variation/
    # ModifierGroup/Modifier) carry Square's per-object `version` token, and
    # SpreePos::CatalogSync#map_tax / #map_item / #map_variation rely on
    # that token (`mapping.stale?(square_object.version)`) to skip
    # out-of-order or duplicate webhook deliveries — a real production bug
    # fix (see CatalogSync's own comments; R2 in the plan's risk register
    # calls this class of regression out by name). Routing today's sync
    # through this method would silently drop that protection, and would
    # also break catalog_importer_spec.rb's SpreeSquare::CatalogObjectMapper
    # -based mocks in ways beyond a namespace edit. Kept here, tested in
    # isolation (see catalog_adapter_spec.rb), ready to become the live path
    # once the DTOs grow an optional external_version / external_updated_at
    # field mirroring the one already added to spree_pos_tax_mappings /
    # spree_pos_external_refs.
    def to_snapshot(fetch_result)
      SpreePos::Catalog::Snapshot.new(
        categories: fetch_result.categories.map { |o| category_dto(o) },
        modifier_groups: fetch_result.modifier_lists.map { |o| modifier_group_dto(o) },
        taxes: fetch_result.taxes.map { |o| tax_dto(o) },
        items: fetch_result.items.map { |o| item_dto(o, fetch_result.related_objects_by_id) }
      )
    end

    private

    def category_dto(square_object)
      data = square_object.category_data
      SpreePos::Catalog::Category.new(external_id: square_object.id, name: data.name.presence || 'Uncategorized')
    end

    def tax_dto(square_object)
      data = square_object.tax_data
      SpreePos::Catalog::Tax.new(
        external_id: square_object.id,
        name: data.name.presence || 'Square Tax',
        percentage: data.percentage.presence&.to_d || 0,
        included_in_price: (data.inclusion_type == 'INCLUSIVE'),
        enabled: data.enabled != false
      )
    end

    def modifier_group_dto(square_object)
      data = square_object.modifier_list_data
      SpreePos::Catalog::ModifierGroup.new(
        external_id: square_object.id,
        name: data.name.presence || 'Options',
        selection_type: data.selection_type.presence || 'SINGLE',
        min_selected: data.min_selected_modifiers,
        max_selected: data.max_selected_modifiers,
        modifiers: Array(data.modifiers).map { |m| modifier_dto(m) }
      )
    end

    def modifier_dto(square_object)
      data = square_object.modifier_data
      SpreePos::Catalog::Modifier.new(
        external_id: square_object.id,
        name: data.name.presence || 'Option',
        price_cents: data.price_money&.amount || 0
      )
    end

    def item_dto(square_object, related_objects_by_id)
      data = square_object.item_data
      image_object = related_objects_by_id[data.image_ids&.first]
      category_ids = Array(data.category_id) + Array(data.categories).map(&:id)
      modifier_group_ids = Array(data.modifier_list_info).reject { |i| i.enabled == false }.map(&:modifier_list_id)

      SpreePos::Catalog::Item.new(
        external_id: square_object.id,
        name: data.name.presence || 'Untitled item',
        description: data.description,
        image_url: image_object&.image_data&.url,
        category_external_ids: category_ids.uniq,
        tax_external_ids: Array(data.tax_ids),
        modifier_group_external_ids: modifier_group_ids,
        variations: Array(data.variations).map { |v| variation_dto(v) },
        available_at_external_location_ids: Array(data.present_at_location_ids)
      )
    end

    def variation_dto(square_object)
      data = square_object.item_variation_data
      SpreePos::Catalog::Variation.new(
        external_id: square_object.id,
        name: data.name,
        sku: square_object.id,
        price_cents: data.price_money&.amount || 0,
        currency: data.price_money&.currency
      )
    end
  end
end
