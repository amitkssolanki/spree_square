module SpreeSquare
  # Full catalog import: pulls every ITEM + CATEGORY + MODIFIER_LIST + TAX
  # from Square (with related objects — images, referenced categories —
  # inlined via `include_related_objects`) and upserts them into Spree via
  # CatalogObjectMapper. Categories, modifier lists, and taxes are imported
  # before items so an item can resolve its `category_id` /
  # `modifier_list_info` / `tax_ids` to an already-mapped record.
  class CatalogImporter
    Result = Struct.new(:categories_count, :modifier_lists_count, :taxes_count, :items_count, keyword_init: true)

    def self.call = new.call

    def call
      client = SpreeSquare::Client.instance
      objects, related_by_id = fetch_all(client)

      by_type = objects.group_by(&:type)
      categories = by_type.fetch('CATEGORY', [])
      modifier_lists = by_type.fetch('MODIFIER_LIST', [])
      taxes = by_type.fetch('TAX', [])
      items = by_type.fetch('ITEM', [])

      mapper = CatalogObjectMapper.new(related_objects_by_id: related_by_id)
      categories.each { |category| mapper.map_category(category) }
      modifier_lists.each { |list| mapper.map_modifier_list(list) }
      taxes.each { |tax| mapper.map_tax(tax) }
      items.each { |item| mapper.map_item(item) }

      Result.new(categories_count: categories.size, modifier_lists_count: modifier_lists.size,
                 taxes_count: taxes.size, items_count: items.size)
    end

    private

    # Square's search is a single page per call; loop on `cursor` until
    # exhausted. Fine for a restaurant-sized catalog (dozens to low hundreds
    # of items) — not built for bulk/enterprise catalogs.
    def fetch_all(client)
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

      [objects, related_by_id]
    end
  end
end
