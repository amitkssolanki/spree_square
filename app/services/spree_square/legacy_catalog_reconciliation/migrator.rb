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
      def initialize(connection: nil)
        @connection = connection
      end

      # @return [Report] the same report the dry run would have produced,
      #   with `applied` filled in.
      def call
        report = Analyzer.new(connection: @connection).call
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
