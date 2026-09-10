module SpreeSquare
  module LegacyCatalogReconciliation
    # The mutating half. Writes SpreePos::ExternalRef rows for exactly the
    # findings the analyzer classified as convertible, and nothing else.
    #
    # What it will never do, by construction rather than by care:
    #
    #   * decide anything the analyzer did not already decide (it holds no
    #     classification logic of its own)
    #   * overwrite an ExternalRef that conflicts with a legacy row
    #     (conflicts are not convertible, so they are never in the list)
    #   * delete or edit a legacy mapping row (this class never loads one
    #     for writing, and issues no DELETE or UPDATE against either legacy
    #     table)
    #   * invent version metadata (external_version and last_synced_at are
    #     copied from the legacy row verbatim)
    #
    # Idempotency comes from the analyzer too: a row this class already
    # migrated classifies as :unchanged on the next run, so a second
    # invocation writes nothing. The `find_or_initialize_by` below is a
    # second, independent guard for the same thing, not the primary one --
    # it is what keeps two concurrent invocations from both inserting.
    class Migrator
      # Raised INSTEAD of mutating when a hard invariant does not hold.
      # Every one of these means the world is not the shape the analysis
      # assumed, and applying anyway would be acting on a stale plan.
      class InvariantViolation < SpreePos::PermanentError; end

      def initialize(connection: nil, allow_unresolved: false)
        @connection = connection
        @allow_unresolved = allow_unresolved
      end

      # @return [Report] the same report the dry run would have produced,
      #   with `applied` filled in.
      # @raise [InvariantViolation] before writing anything, if the
      #   pre-mutation checks fail.
      def call
        report = Analyzer.new(connection: @connection).call
        enforce_invariants!(report)
        applied = []

        # One transaction for the whole batch: a half-migrated catalog is
        # far worse to reason about than a failed migration, and the row
        # counts here (production: tens, not millions) make an all-or-
        # nothing apply entirely practical.
        SpreePos::ExternalRef.transaction do
          report.convertible.each { |finding| applied << apply(finding) }
          applied.compact!
        end

        Report.new(report.findings, applied: applied)
      end

      private

      # The refusal gate. Runs BEFORE the transaction opens, so a violation
      # costs nothing and leaves nothing half-done.
      #
      # These are not style checks. Each one is a way the cutover could
      # proceed on a false premise:
      def enforce_invariants!(report)
        violations = []

        # 1. Unresolved rows mean a human has not finished deciding. The
        #    default is to refuse; `allow_unresolved:` exists for the
        #    deliberate case where the operator has reviewed them and wants
        #    the convertible rows migrated anyway, and it has to be typed
        #    out on purpose.
        if report.unresolved.any? && !@allow_unresolved
          violations << "#{report.unresolved.size} row(s) still need human resolution " \
                        "(#{report.unresolved.map(&:classification).tally.map { |k, v| "#{k}: #{v}" }.join(', ')}). " \
                        'Resolve them, or pass allow_unresolved: true to migrate only the convertible rows.'
        end

        # 2. A convertible row with no connection would insert a NULL into a
        #    NOT NULL column and abort the transaction mid-flight. Cheaper
        #    and clearer to refuse up front.
        orphans = report.convertible.select { |f| f.pos_connection_id.blank? }
        if orphans.any?
          violations << "#{orphans.size} convertible row(s) carry no POS connection, which cannot be written " \
                        "(spree_pos_external_refs.pos_connection_id is NOT NULL): " \
                        "#{orphans.first(5).map(&:external_id).join(', ')}"
        end

        # 3. Two convertible rows targeting the same (connection, type,
        #    external_id) would violate the unique index. The analyzer
        #    classifies that as duplicate_legacy_mapping, so reaching here
        #    means the classification and the plan disagree, which is a bug
        #    in the tooling rather than in the data.
        dupes = report.convertible
                      .group_by { |f| [f.pos_connection_id, f.resource_type, f.external_id] }
                      .select { |_, group| group.size > 1 }
        if dupes.any?
          violations << "#{dupes.size} convertible group(s) share an (connection, resource_type, external_id) " \
                        'tuple. The analyzer should have classified these as duplicates; this is a tooling bug, ' \
                        'not a data problem. Do not force it.'
        end

        # 4. Same for the per-record unique index, which is PARTIAL:
        #    categories are exempt because many external categories
        #    legitimately collapse onto one taxon (37 to 8 in production).
        #    Applying the item rule to categories here would resurrect
        #    exactly the false-conflict bug the partial index exists to
        #    avoid.
        record_dupes = report.convertible
                             .reject { |f| f.resource_type == SpreePos::ExternalRef::RESOURCE_CATEGORY }
                             .group_by { |f| [f.pos_connection_id, f.resource_type, f.spree_type, f.spree_id] }
                             .select { |_, group| group.size > 1 }
        if record_dupes.any?
          violations << "#{record_dupes.size} convertible non-category group(s) target the same Spree record. " \
                        'ExternalRef allows only one per connection; the analyzer should have surfaced these ' \
                        'as collisions.'
        end

        return if violations.empty?

        raise InvariantViolation,
              "REFUSING TO MUTATE. #{violations.size} invariant(s) failed:\n" +
              violations.map.with_index(1) { |v, i| "  #{i}. #{v}" }.join("\n")
      end

      def apply(finding)
        connection = SpreePos::Connection.find(finding.pos_connection_id)

        ref = SpreePos::ExternalRef
              .for_connection(connection)
              .of_type(finding.resource_type)
              .find_or_initialize_by(external_id: finding.external_id)

        # Only reachable if a concurrent writer created the row between the
        # analysis and this transaction. Leaving it alone is the same
        # promise the conflict classifications make: a row that already
        # exists was written by a real sync, and this migration does not
        # get to second-guess it.
        return nil if ref.persisted?

        ref.pos_connection = connection
        ref.spree_type = finding.spree_type
        ref.spree_id = finding.spree_id
        ref.external_version = finding.external_version
        ref.last_synced_at = finding.last_synced_at
        ref.save!

        finding
      end
    end
  end
end
