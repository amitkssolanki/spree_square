module SpreeSquare
  # Maps a Square catalog object (ITEM or ITEM_VARIATION) to the Spree record
  # it was imported into. `square_version` is Square's optimistic-concurrency
  # token — compared before writing so out-of-order or duplicate webhook
  # delivery (M3) can't clobber newer data with older data.
  class CatalogMapping < Spree.base_class
    self.table_name = 'spree_square_catalog_mappings'

    ITEM = 'item'.freeze
    ITEM_VARIATION = 'item_variation'.freeze

    belongs_to :product, class_name: 'Spree::Product', foreign_key: 'spree_product_id', optional: true
    belongs_to :variant, class_name: 'Spree::Variant', foreign_key: 'spree_variant_id', optional: true

    validates :square_catalog_object_id, presence: true, uniqueness: true
    validates :square_object_type, presence: true, inclusion: { in: [ITEM, ITEM_VARIATION] }

    # True if `incoming_version` is not newer than what we already recorded —
    # i.e. it's safe to skip re-processing (duplicate or out-of-order
    # delivery).
    def stale?(incoming_version)
      square_version.present? && incoming_version.present? && incoming_version <= square_version
    end
  end
end
