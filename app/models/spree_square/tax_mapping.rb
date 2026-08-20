module SpreeSquare
  # Mirrors one Square CatalogTax object — a plain flat percentage + an
  # inclusion type, category-agnostic. Square's Catalog API has no concept
  # of jurisdiction/zone at all, so this row never points at a
  # Spree::TaxRate directly: which Spree::TaxCategory (and therefore which
  # Spree::TaxRate) a given Square tax participates in depends on which
  # *combination* of Square taxes each item carries — see
  # TaxCategoryMapping and CatalogObjectMapper#resolve_tax_category.
  #
  # `square_version` is Square's optimistic-concurrency token — same
  # stale-check pattern as CatalogMapping, guards against out-of-order or
  # duplicate webhook delivery re-processing older data over newer.
  class TaxMapping < Spree.base_class
    self.table_name = 'spree_square_tax_mappings'

    has_many :tax_category_mappings, class_name: 'SpreeSquare::TaxCategoryMapping', dependent: :destroy

    validates :square_tax_id, presence: true, uniqueness: true

    def stale?(incoming_version)
      square_version.present? && incoming_version.present? && incoming_version <= square_version
    end
  end
end
