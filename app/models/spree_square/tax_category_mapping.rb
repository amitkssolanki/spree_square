module SpreeSquare
  # Join row: "in this Spree::TaxCategory, this Square tax is represented by
  # this Spree::TaxRate." A composite category (an item carrying more than
  # one Square tax at once) has one row per constituent tax. See
  # CatalogObjectMapper#resolve_tax_category for how this is used to
  # find-or-create the right category for an item's exact set of Square tax
  # ids, and TaxMapping for why this can't just be a belongs_to on
  # TaxMapping itself (one Square tax can back rates in more than one
  # category).
  class TaxCategoryMapping < Spree.base_class
    self.table_name = 'spree_square_tax_category_mappings'

    # `with_deleted` (mirrors Spree::TaxRate's own belongs_to :tax_category)
    # — without it, a soft-deleted (disabled-in-Square) rate becomes
    # unreachable through this association, which would break re-enabling
    # it later: CatalogObjectMapper#sync_enabled_state! needs to find and
    # restore the very row it previously destroyed.
    belongs_to :tax_category, class_name: 'Spree::TaxCategory'
    belongs_to :tax_mapping, class_name: 'SpreeSquare::TaxMapping'
    belongs_to :tax_rate, -> { with_deleted }, class_name: 'Spree::TaxRate'

    validates :tax_mapping_id, uniqueness: { scope: :tax_category_id }
  end
end
