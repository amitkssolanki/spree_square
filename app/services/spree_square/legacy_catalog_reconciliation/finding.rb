module SpreeSquare
  module LegacyCatalogReconciliation
    # One classified legacy mapping row. Carries everything an operator
    # needs to resolve a non-convertible row by hand without going back to
    # the database (brief section 5): who owns it, what it points at, which
    # legacy row it came from, and -- for the conflict classifications --
    # what it collides with.
    Finding = Struct.new(
      :classification,
      :resource_type,
      :external_id,
      :spree_type,
      :spree_id,
      :external_version,
      :last_synced_at,
      :legacy_table,
      :legacy_id,
      :pos_connection_id,
      :pos_connection_merchant_id,
      :store_id,
      :existing_ref_id,
      :conflicting_external_id,
      :conflicting_spree_type,
      :conflicting_spree_id,
      :colliding_external_ids,
      :detail,
      keyword_init: true
    )

    # Reopened rather than passed as a block to Struct.new: constants
    # defined inside that block land on the ENCLOSING module, not on the
    # struct class, so `Finding::ALL` would not resolve.
    class Finding
      # The classifications the migrator is allowed to write. Everything
      # else is reported and left alone.
      #
      # `category_many_to_one_accepted` is convertible ON PURPOSE and is
      # the single most important line in this file: many external
      # categories legitimately collapse onto one Spree::Taxon (37 -> 8 in
      # production), spree_pos_external_refs' unique index carries a
      # matching `WHERE resource_type <> 'category'` exemption, and
      # reporting those as conflicts would have stalled the entire cutover
      # on 29 false positives.
      CONVERTIBLE = %i[convertible category_many_to_one_accepted].freeze

      # Fixed order, so a report's sections and counts are byte-identical
      # across runs on unchanged data.
      ALL = %i[
        convertible
        category_many_to_one_accepted
        already_represented
        unchanged
        missing_connection
        missing_spree_target
        duplicate_legacy_mapping
        item_collision
        variation_collision
        conflicting_target
        ambiguous
      ].freeze

      def convertible? = CONVERTIBLE.include?(classification)

      # Stable sort key. Deliberately NOT the legacy row id: ids differ
      # between the production database and any fixture built to imitate
      # it, and a report whose row order depends on insertion order is not
      # comparable across environments.
      def sort_key = [resource_type.to_s, external_id.to_s]

      def to_h = super.compact
    end
  end
end
