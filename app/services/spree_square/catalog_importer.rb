module SpreeSquare
  # Full catalog import: pulls every ITEM + CATEGORY + MODIFIER_LIST + TAX
  # from Square and upserts them into Spree. Categories, modifier groups,
  # and taxes are imported before items so an item can resolve its
  # category / modifier-group / tax references to an already-mapped record.
  #
  # B3: this now runs entirely on the provider-neutral DTO contract. It
  # asks the adapter for a `SpreePos::Catalog::Snapshot` and hands those
  # DTOs straight to `SpreePos::CatalogSync` — no raw Square SDK object
  # crosses into spree_pos any more, and this class no longer needs the
  # `SpreeSquare::CatalogObjectMapper` facade at all.
  #
  # The import ORDER is load-bearing and unchanged: categories, then
  # modifier groups, then taxes, then items. `map_item` resolves each of
  # those three by external id against rows this loop has already written.
  #
  # PRUNING (2.4.1, OI-195). Until 2.4.0 nothing deleted in Square ever left
  # Spree: a deleted dish stayed on sale, a deleted option stayed choosable,
  # and its id went to Square on the next order. The import now removes what
  # the listing no longer has, under three guards:
  #
  #   1. Only after a COMPLETE listing. CatalogAdapter#fetch_raw pages the
  #      whole catalog or raises (any API error, a repeated cursor, a page
  #      cap), and a raise here happens before anything is mapped or pruned.
  #      A listing that needed more than one page is listed a second time and
  #      an id seen by either pass counts as present (spree_clover's OI-162
  #      #9 guard).
  #   2. Only after every object mapped. #prune_missing! runs last; an error
  #      mapping any item propagates out before it.
  #   3. Only within the cap (CatalogPrunePlan). Over it, no removal of any
  #      kind is made on this run, additions and changes still apply, and an
  #      alert names the counts.
  #
  # Removal is soft where Spree allows it: items and variations are
  # discontinued (archived), never deleted, and come back if Square lists
  # them again. Modifier options and categories follow spree_pos's own rules
  # (option rows removed with past-order snapshots kept; a category's taxon
  # deleted only when the connection owns everything in it).
  class CatalogImporter
    Result = Struct.new(:categories_count, :modifier_lists_count, :taxes_count, :items_count,
                        :products_pruned, :variants_pruned, :categories_pruned, :removals_withheld,
                        :warnings, :proposals, keyword_init: true)

    # Raised only when the cap is exceeded and the installed spree_pos cannot
    # withhold removals on its own (a spree_pos without
    # CatalogSync#removals_enabled=): then nothing is imported at all rather
    # than removing unchecked. Otherwise it is only reported, never raised.
    class PruneCapExceeded < SpreePos::PermanentError; end

    # `max_prune_fraction:` overrides the cap for one run (an operator who
    # has confirmed in Square that a large removal is real).
    def self.call(connection:, max_prune_fraction: nil) = new(connection: connection, max_prune_fraction: max_prune_fraction).call

    # The connection is required: it decides whose Square catalog is read
    # (its store's credential) and which store the products land in.
    def initialize(connection:, max_prune_fraction: nil)
      @connection = connection
      @max_prune_fraction = max_prune_fraction
    end

    def call
      adapter = SpreeSquare::CatalogAdapter.new(connection: @connection)
      snapshot = adapter.fetch_all

      # B2: no mapping model is injected any more. CatalogSync persists to
      # SpreePos::ExternalRef, its own gem's neutral table, scoped to the
      # connection it resolves.
      sync = SpreePos::CatalogSync.new(connection: @connection)
      plan = SpreeSquare::CatalogPrunePlan.new(connection: @connection, snapshot: snapshot,
                                               extra_present_ids: adapter.extra_present_ids,
                                               max_fraction: @max_prune_fraction)
      withheld = plan.exceeds_cap?
      withhold_removals!(sync, plan) if withheld

      snapshot.categories.each { |category| sync.map_category(category) }
      snapshot.modifier_groups.each { |group| sync.map_modifier_list(group) }
      snapshot.taxes.each { |tax| sync.map_tax(tax) }
      snapshot.items.each { |item| sync.map_item(item) }

      pruned = sync.prune_missing!(seen_item_external_ids: plan.seen_item_external_ids,
                                   seen_variation_external_ids: plan.seen_variation_external_ids,
                                   seen_category_external_ids: plan.seen_category_external_ids)

      Result.new(categories_count: snapshot.categories.size, modifier_lists_count: snapshot.modifier_groups.size,
                 taxes_count: snapshot.taxes.size, items_count: snapshot.items.size,
                 products_pruned: pruned[:products].to_i, variants_pruned: pruned[:variants].to_i,
                 categories_pruned: pruned[:categories].to_i, removals_withheld: withheld ? 1 : 0,
                 warnings: Array(sync.warnings), proposals: Array(sync.proposals))
    end

    private

    def withhold_removals!(sync, plan)
      message = "Square catalog import for connection #{@connection.id} would remove more than " \
                "#{(plan.max_fraction * 100).round}% of: #{plan.over_cap.join(', ')} (#{plan.summary}); " \
                'no removal was made. Check the Square catalog; if the change is real, run the import once with ' \
                'a higher max_prune_fraction.'
      error = PruneCapExceeded.new(message)
      SpreeSquare::Alerting.capture(error, context: { area: 'catalog_prune_cap', connection_id: @connection.id,
                                                      removals: plan.removals, baseline: plan.baseline })
      raise error unless sync.respond_to?(:removals_enabled=)

      sync.removals_enabled = false
      sync.warnings << message
    end
  end
end
