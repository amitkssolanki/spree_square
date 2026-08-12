module SpreeSquare
  # Maps a Square Category to a Spree::Category — the modern, store-scoped
  # replacement for the legacy Taxonomy-backed Taxon system (see
  # Spree::Category's own comment; it becomes the base class in Spree 6.0).
  #
  # Spree::Category isn't true STI (spree_taxons has no `type` column to
  # dispatch on) — it's a plain Taxon subclass distinguished only by
  # `default_scope { manual }` and an overridden `requires_taxonomy?`
  # (false, vs. Taxon's own `true`). That means the association's
  # `class_name` is what determines which class `#taxon` instantiates as,
  # not the row's own data. Declaring it as `'Spree::Taxon'` here meant
  # every re-fetched taxon silently reverted to the base class — Category's
  # `requires_taxonomy?` override never applied, so any re-save (e.g. a
  # name update from a later Square sync) failed with a bogus "Taxonomy
  # can't be blank", even though the taxon was created as a Category with
  # no taxonomy in the first place.
  class TaxonMapping < Spree.base_class
    self.table_name = 'spree_square_taxon_mappings'

    belongs_to :taxon, class_name: 'Spree::Category', foreign_key: 'spree_taxon_id'

    validates :square_category_id, presence: true, uniqueness: true
    validates :taxon, presence: true
  end
end
