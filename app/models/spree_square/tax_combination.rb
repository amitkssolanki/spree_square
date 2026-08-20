module SpreeSquare
  # One row per distinct combination of Square tax ids an item carries at
  # once, keyed by `signature` (sorted, comma-joined SpreeSquare::TaxMapping
  # ids) — the race-safe find-or-create key `create_or_find_by!` needs. See
  # CatalogObjectMapper#composite_tax_category for why this exists: without
  # a real unique index to race against, two concurrent imports resolving
  # the same combination for the first time could each create their own
  # Spree::TaxCategory.
  class TaxCombination < Spree.base_class
    self.table_name = 'spree_square_tax_combinations'

    belongs_to :tax_category, class_name: 'Spree::TaxCategory'

    # Deliberately NO `uniqueness: true` here — that's a validation-layer
    # SELECT-then-INSERT check with exactly the same race this table exists
    # to close. `create_or_find_by!` (see CatalogObjectMapper#
    # composite_tax_category) depends on the real DB-level unique index
    # (the migration's `add_index ... unique: true`) raising
    # ActiveRecord::RecordNotUnique on the losing INSERT, which is the one
    # thing it explicitly rescues — a uniqueness validation raises
    # RecordInvalid instead, which it does not, and defeats the whole
    # point (confirmed live: adding this validation back made the second,
    # non-racing call in this file's own idempotency spec raise instead of
    # transparently finding the row).
    validates :signature, presence: true

    def self.signature_for(tax_mapping_ids)
      tax_mapping_ids.sort.join(',')
    end
  end
end
