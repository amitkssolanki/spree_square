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

    # `client:` is resolved LAZILY (B3). It used to default to
    # `SpreeSquare::Client.instance` in the argument list, which meant
    # merely CONSTRUCTING this adapter reached for a credential and raised
    # when none was connected. That mattered the moment
    # SpreeSquare::CatalogObjectMapper started building one just to
    # convert a single object to a DTO — conversion needs no credential at
    # all. Only the methods that actually talk to Square (#fetch_raw) do.
    def initialize(client: nil)
      @client = client
    end

    # The provider contract's catalog-import entry point, added for
    # Package B1 (registry-dispatched catalog ORCHESTRATION only).
    #
    # `SpreePos::CatalogWebhookJob` / `SpreePos::ReconciliationJob` used to
    # call `SpreeSquare::CatalogImporter.call` by name from inside
    # spree_pos. They now reach this method as `provider.catalog.import!`,
    # so the provider-neutral layer no longer names Square. What happens
    # BELOW this line is deliberately unchanged:
    #
    #   import! -> SpreeSquare::CatalogImporter
    #           -> SpreeSquare::CatalogObjectMapper (thin facade)
    #           -> SpreePos::CatalogSync
    #
    # and SpreePos::CatalogSync still consumes raw Square SDK objects and
    # still persists product/variant/category ids to the legacy
    # SpreeSquare::CatalogMapping / TaxonMapping tables. That is B1's
    # explicit scope: dispatch is provider-neutral, the mapper underneath
    # is not yet. See spree_pos/README.md's "Catalog: known technical
    # debt" section for the two follow-up tasks (B2 ExternalRef, B3 DTOs)
    # and why neither is done here.
    #
    # Note this is a method on the catalog SUB-ADAPTER, not a change to
    # SpreePos::Provider itself: the registry validates that a provider
    # responds to `catalog`, never what the returned object responds to.
    def import!
      SpreeSquare::CatalogImporter.call
    end

    # The provider contract's catalog-read entry point
    # (plan section 8.1: `#fetch_all -> SpreePos::Catalog::Snapshot`).
    #
    # Package A: this name used to return the Square-shaped `FetchResult`
    # below, which meant SpreeSquare::CatalogAdapter did NOT satisfy the
    # contract it claimed to — caught the first time the shared
    # `it_behaves_like 'a POS provider'` group was actually run against
    # Square, which had never happened while no SpreeSquare::Provider
    # existed. The raw fetch keeps its behaviour verbatim under its own
    # name (#fetch_raw); only the contract-facing name changed hands.
    #
    # Note what this does NOT change: the live import path still uses
    # #fetch_raw, because SpreePos::CatalogSync consumes raw Square SDK
    # objects and depends on their `version` token, which none of the
    # SpreePos::Catalog DTOs carry (see #to_snapshot's own comment). That
    # is exactly the B3 debt, and it is deliberately untouched here.
    def fetch_all
      to_snapshot(fetch_raw)
    end

    # Square's search is a single page per call; loop on `cursor` until
    # exhausted. Fine for a restaurant-sized catalog (dozens to low hundreds
    # of items) — not built for bulk/enterprise catalogs. (Moved verbatim
    # from CatalogImporter#fetch_all.)
    #
    # Square-shaped on purpose: returns the SDK's own catalog objects,
    # grouped by type, because that is what the existing import pipeline
    # needs. Renamed from #fetch_all in Package A so the contract-conforming
    # name could return a Snapshot; the body is unchanged.
    def fetch_raw
      objects = []
      related_by_id = {}
      cursor = nil

      loop do
        response = client.catalog.search(
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

    # Resolved on first real use, never at construction. See #initialize.
    def client
      @client ||= SpreeSquare::Client.instance
    end

    # ------------------------------------------------------------------
    # Per-object DTO builders. Public because SpreeSquare::CatalogObjectMapper
    # (the retained backward-compatibility facade) converts a single raw
    # Square object at a time through these before handing it to
    # SpreePos::CatalogSync, which as of B3 accepts only DTOs.
    #
    # `external_version` is Square's own per-object `version` token — the
    # optimistic-concurrency value CatalogSync's staleness guard has always
    # depended on. Carrying it on the DTO is what makes the provider-neutral
    # sync layer able to keep that protection without knowing it is Square's.
    # `external_updated_at` is left nil: Square objects have no separate
    # last-modified timestamp, and `version` is strictly better. A provider
    # with only a timestamp (Clover's `modifiedTime`) populates the other
    # field instead; SpreePos::Catalog::Staleness prefers whichever is
    # available, version first.
    # ------------------------------------------------------------------

    def category_dto(square_object)
      data = square_object.category_data
      SpreePos::Catalog::Category.new(
        external_id: square_object.id,
        name: data.name.presence || 'Uncategorized',
        external_version: square_object.version
      )
    end

    def tax_dto(square_object)
      data = square_object.tax_data
      SpreePos::Catalog::Tax.new(
        external_id: square_object.id,
        name: data.name.presence || 'Square Tax',
        percentage: data.percentage.presence&.to_d || 0,
        included_in_price: (data.inclusion_type == 'INCLUSIVE'),
        enabled: data.enabled != false,
        external_version: square_object.version
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
        modifiers: Array(data.modifiers).map { |m| modifier_dto(m) },
        external_version: square_object.version
      )
    end

    def modifier_dto(square_object)
      data = square_object.modifier_data
      SpreePos::Catalog::Modifier.new(
        external_id: square_object.id,
        name: data.name.presence || 'Option',
        price_cents: data.price_money&.amount || 0,
        external_version: square_object.version
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
        available_at_external_location_ids: Array(data.present_at_location_ids),
        external_version: square_object.version
      )
    end

    def variation_dto(square_object)
      data = square_object.item_variation_data
      SpreePos::Catalog::Variation.new(
        external_id: square_object.id,
        name: data.name,
        sku: square_object.id,
        price_cents: data.price_money&.amount || 0,
        currency: data.price_money&.currency,
        external_version: square_object.version
      )
    end
  end
end
