module SpreeSquare
  # Full catalog import: pulls every ITEM + CATEGORY + MODIFIER_LIST + TAX
  # from Square (with related objects — images, referenced categories —
  # inlined via `include_related_objects`) and upserts them into Spree via
  # CatalogObjectMapper. Categories, modifier lists, and taxes are imported
  # before items so an item can resolve its `category_id` /
  # `modifier_list_info` / `tax_ids` to an already-mapped record.
  #
  # Phase 2, step 14 of the multi-POS/multi-location plan: the fetch/
  # pagination concern (talking to Square) now lives in CatalogAdapter; this
  # class is the thin job wrapper — fetch, then hand each group to the
  # mapper in the same fixed order as before.
  class CatalogImporter
    Result = Struct.new(:categories_count, :modifier_lists_count, :taxes_count, :items_count, keyword_init: true)

    def self.call = new.call

    def call
      fetched = SpreeSquare::CatalogAdapter.new.fetch_all
      mapper = SpreeSquare::CatalogObjectMapper.new(related_objects_by_id: fetched.related_objects_by_id)

      fetched.categories.each { |category| mapper.map_category(category) }
      fetched.modifier_lists.each { |list| mapper.map_modifier_list(list) }
      fetched.taxes.each { |tax| mapper.map_tax(tax) }
      fetched.items.each { |item| mapper.map_item(item) }

      Result.new(categories_count: fetched.categories.size, modifier_lists_count: fetched.modifier_lists.size,
                 taxes_count: fetched.taxes.size, items_count: fetched.items.size)
    end
  end
end
