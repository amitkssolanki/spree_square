module SpreeSquare
  module LegacyCatalogReconciliation
    # The report-only half. Performs ZERO writes: every database call below
    # is a read, and the class holds no code path that could create,
    # update, or delete anything. That is what makes it safe to run against
    # production before the cutover is approved.
    #
    # The migrator consumes this class's output rather than repeating any
    # of its reasoning, so the dry run and the mutation cannot disagree.
    class Analyzer
      # A legacy row flattened into the shape ExternalRef stores, so items,
      # variations, and categories can all be classified by one code path
      # regardless of which legacy table (and which column names) they came
      # from.
      LegacyRow = Struct.new(
        :legacy_table, :legacy_id, :resource_type, :external_id, :spree_type, :spree_id,
        :external_version, :last_synced_at, :shape_error, :pos_connection, :store_id,
        keyword_init: true
      )

      def initialize(connection: nil)
        @pinned_connection = connection
        @connection_by_store_id = {}
      end

      def call
        rows = legacy_rows
        rows.each { |row| attach_connection(row) }

        by_external = rows.group_by { |row| [row.pos_connection&.id, row.resource_type, row.external_id] }
        by_target = rows.select(&:spree_id)
                        .group_by { |row| [row.pos_connection&.id, row.resource_type, row.spree_type, row.spree_id] }

        Report.new(rows.map { |row| classify(row, by_external, by_target) })
      end

      private

      # ------------------------------------------------------------------
      # Reading the legacy tables
      # ------------------------------------------------------------------

      def legacy_rows
        catalog_rows + taxon_rows
      end

      def catalog_rows
        SpreeSquare::CatalogMapping.order(:square_catalog_object_id).map do |mapping|
          row = LegacyRow.new(
            legacy_table: SpreeSquare::CatalogMapping.table_name,
            legacy_id: mapping.id,
            external_id: mapping.square_catalog_object_id,
            external_version: mapping.square_version,
            last_synced_at: mapping.last_synced_at
          )
          apply_catalog_shape(row, mapping)
          row
        end
      end

      # Neither legacy column is NOT NULL and nothing stops a row carrying
      # both, so the shape is validated here rather than assumed. A row
      # that cannot be read unambiguously is reported as :ambiguous and is
      # never guessed at.
      def apply_catalog_shape(row, mapping)
        case mapping.square_object_type
        when SpreeSquare::CatalogMapping::ITEM
          row.resource_type = SpreePos::ExternalRef::RESOURCE_ITEM
          row.spree_type = 'Spree::Product'
          row.spree_id = mapping.spree_product_id
          row.shape_error = 'row is typed as an item but also carries a variant id' if mapping.spree_variant_id
        when SpreeSquare::CatalogMapping::ITEM_VARIATION
          row.resource_type = SpreePos::ExternalRef::RESOURCE_VARIATION
          row.spree_type = 'Spree::Variant'
          row.spree_id = mapping.spree_variant_id
          row.shape_error = 'row is typed as a variation but also carries a product id' if mapping.spree_product_id
        else
          row.resource_type = mapping.square_object_type.to_s
          row.shape_error = "unrecognised legacy object type #{mapping.square_object_type.inspect}"
        end
      end

      def taxon_rows
        SpreeSquare::TaxonMapping.order(:square_category_id).map do |mapping|
          LegacyRow.new(
            legacy_table: SpreeSquare::TaxonMapping.table_name,
            legacy_id: mapping.id,
            resource_type: SpreePos::ExternalRef::RESOURCE_CATEGORY,
            external_id: mapping.square_category_id,
            # Spree::Taxon, not Spree::Category: the polymorphic column has
            # to hold the class the row's own table reports, and this is
            # exactly what SpreePos::ExternalRef::SPREE_TYPE_FOR and the
            # Phase 3 absorb migration both write.
            spree_type: SpreePos::ExternalRef::SPREE_TYPE_FOR.fetch(SpreePos::ExternalRef::RESOURCE_CATEGORY),
            spree_id: mapping.spree_taxon_id,
            external_version: mapping.square_version
          )
        end
      end

      # ------------------------------------------------------------------
      # Connection resolution
      #
      # The legacy tables carry no connection and no store: they were built
      # when there was exactly one of each. So ownership has to be derived
      # from the Spree record the row points at (its store's catalog-source
      # connection), unless the operator pins one explicitly.
      # ------------------------------------------------------------------

      def attach_connection(row)
        record = spree_record(row)
        row.store_id = store_id_for(record)

        row.pos_connection = @pinned_connection || connection_for_store(row.store_id)
      end

      def connection_for_store(store_id)
        return nil if store_id.nil?

        @connection_by_store_id.fetch(store_id) do
          @connection_by_store_id[store_id] =
            SpreePos::Connection.find_by(store_id: store_id, catalog_role: 'source')
        end
      end

      def store_id_for(record)
        case record
        when nil then nil
        when Spree::Variant then record.product&.store_id
        when Spree::Taxon then record.store_id || record.taxonomy&.store_id
        else record.store_id
        end
      end

      def spree_record(row)
        return nil if row.spree_type.blank? || row.spree_id.blank?

        row.spree_type.constantize.find_by(id: row.spree_id)
      end

      # ------------------------------------------------------------------
      # Classification
      # ------------------------------------------------------------------

      # Order is load-bearing. A row is described by the FIRST reason it
      # cannot be converted, cheapest and most fundamental first, so the
      # report never blames a collision on a row whose real problem is a
      # deleted product or an unresolvable connection.
      def classify(row, by_external, by_target)
        finding = base_finding(row)

        return finalize(finding, :ambiguous, row.shape_error) if row.shape_error.present?
        return finalize(finding, :missing_spree_target, missing_target_detail(row)) unless spree_record(row)
        return finalize(finding, :missing_connection, missing_connection_detail(row)) if row.pos_connection.nil?

        duplicates = by_external[[row.pos_connection.id, row.resource_type, row.external_id]]
        if duplicates.size > 1
          finding.colliding_external_ids = duplicates.map(&:legacy_id).sort
          return finalize(finding, :duplicate_legacy_mapping,
                          "#{duplicates.size} legacy rows claim external id #{row.external_id.inspect} for this " \
                          'connection and resource type; only one can exist as an ExternalRef')
        end

        siblings = by_target[[row.pos_connection.id, row.resource_type, row.spree_type, row.spree_id]]
        other_external_ids = siblings.map(&:external_id).uniq.reject { |id| id == row.external_id }.sort
        many_to_one = other_external_ids.any?

        if many_to_one && !category?(row)
          finding.colliding_external_ids = other_external_ids
          return finalize(finding, collision_classification(row), collision_detail(row, other_external_ids))
        end

        classify_against_existing_refs(finding, row, many_to_one)
      end

      def classify_against_existing_refs(finding, row, many_to_one)
        scope = SpreePos::ExternalRef.for_connection(row.pos_connection).of_type(row.resource_type)
        existing = scope.find_by(external_id: row.external_id)

        return classify_against_matching_ref(finding, row, existing) if existing

        # Nothing claims this external id, but for a non-category resource
        # something else may already claim the Spree record, and
        # spree_pos_external_refs' partial unique index forbids a second
        # claim. Converting anyway would raise mid-cutover; reporting it
        # keeps the mutation's promise never to pick a winner.
        occupant = category?(row) ? nil : scope.find_by(spree_type: row.spree_type, spree_id: row.spree_id)
        if occupant
          finding.existing_ref_id = occupant.id
          finding.conflicting_external_id = occupant.external_id
          return finalize(finding, :conflicting_target,
                          "an ExternalRef for external id #{occupant.external_id.inspect} already claims " \
                          "#{row.spree_type}##{row.spree_id} under this connection")
        end

        return finalize(finding, :category_many_to_one_accepted, category_many_to_one_detail(row)) if many_to_one

        finalize(finding, :convertible, nil)
      end

      def classify_against_matching_ref(finding, row, existing)
        finding.existing_ref_id = existing.id

        unless existing.spree_type == row.spree_type && existing.spree_id == row.spree_id
          finding.conflicting_spree_type = existing.spree_type
          finding.conflicting_spree_id = existing.spree_id
          return finalize(finding, :conflicting_target,
                          "an ExternalRef for this external id already points at " \
                          "#{existing.spree_type}##{existing.spree_id}, not #{row.spree_type}##{row.spree_id}")
        end

        return finalize(finding, :unchanged, nil) if existing.external_version == row.external_version

        finalize(finding, :already_represented,
                 "already migrated, but the live ExternalRef records external version " \
                 "#{existing.external_version.inspect} where the legacy row records #{row.external_version.inspect}; " \
                 'the live value is left alone because it came from a real sync')
      end

      # ------------------------------------------------------------------

      def base_finding(row)
        Finding.new(
          resource_type: row.resource_type,
          external_id: row.external_id,
          spree_type: row.spree_type,
          spree_id: row.spree_id,
          external_version: row.external_version,
          last_synced_at: row.last_synced_at,
          legacy_table: row.legacy_table,
          legacy_id: row.legacy_id,
          pos_connection_id: row.pos_connection&.id,
          pos_connection_merchant_id: row.pos_connection&.external_merchant_id,
          store_id: row.store_id
        )
      end

      def finalize(finding, classification, detail)
        finding.classification = classification
        finding.detail = detail
        finding
      end

      def category?(row) = row.resource_type == SpreePos::ExternalRef::RESOURCE_CATEGORY

      def collision_classification(row)
        row.resource_type == SpreePos::ExternalRef::RESOURCE_ITEM ? :item_collision : :variation_collision
      end

      def collision_detail(row, other_external_ids)
        "external ids #{([row.external_id] + other_external_ids).sort.inspect} all map to " \
          "#{row.spree_type}##{row.spree_id}; ExternalRef allows only one #{row.resource_type} per Spree record " \
          'per connection, which is the signature of an external object that was deleted and recreated. ' \
          'Decide which external id is current and remove or repoint the others before migrating.'
      end

      def category_many_to_one_detail(row)
        "converted as-is: several external categories legitimately map to #{row.spree_type}##{row.spree_id}, " \
          'which spree_pos_external_refs exempts from its per-record unique index'
      end

      def missing_target_detail(row)
        return "legacy row records no #{row.spree_type.to_s.demodulize.downcase} id" if row.spree_id.blank?

        "#{row.spree_type}##{row.spree_id} no longer exists"
      end

      def missing_connection_detail(row)
        return 'the Spree record belongs to no store, so no POS connection can own this mapping' if row.store_id.nil?

        "store ##{row.store_id} has no SpreePos::Connection with catalog_role 'source' to attribute this mapping to"
      end
    end
  end
end
