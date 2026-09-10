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
  class CatalogImporter
    Result = Struct.new(:categories_count, :modifier_lists_count, :taxes_count, :items_count, keyword_init: true)

    def self.call = new.call

    def call
      adapter = SpreeSquare::CatalogAdapter.new
      snapshot = adapter.fetch_all

      # B2: no mapping model is injected any more. CatalogSync persists to
      # SpreePos::ExternalRef, its own gem's neutral table, scoped to the
      # connection it resolves.
      sync = SpreePos::CatalogSync.new

      snapshot.categories.each { |category| sync.map_category(category) }
      snapshot.modifier_groups.each { |group| sync.map_modifier_list(group) }
      snapshot.taxes.each { |tax| sync.map_tax(tax) }
      snapshot.items.each { |item| sync.map_item(item) }

      Result.new(categories_count: snapshot.categories.size, modifier_lists_count: snapshot.modifier_groups.size,
                 taxes_count: snapshot.taxes.size, items_count: snapshot.items.size)
    end
  end
end
