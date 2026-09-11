require 'digest'

module SpreeSquare
  module LegacyCatalogReconciliation
    # The result of an analysis: every Finding, plus deterministic counts
    # and a human-readable rendering for the operator running the cutover.
    #
    # Holds no database handle and performs no queries of its own -- once
    # built it is a plain value object, which is what makes it safe to
    # capture, diff between runs, and attach to a cutover log.
    class Report
      attr_reader :findings, :applied

      # @param findings [Array<Finding>]
      # @param applied [Array<Finding>] the findings a mutation actually
      #   wrote. Always empty for a dry run -- its presence in the report is
      #   what lets one renderer serve both paths.
      def initialize(findings, applied: [])
        @findings = findings.sort_by(&:sort_key).freeze
        @applied = applied.sort_by(&:sort_key).freeze
      end

      def counts
        @counts ||= Finding::ALL.to_h { |c| [c, findings.count { |f| f.classification == c }] }.freeze
      end

      def convertible = findings.select(&:convertible?)

      # Everything an operator must look at before the cutover can proceed.
      def unresolved
        findings.reject(&:convertible?).reject { |f| %i[unchanged already_represented].include?(f.classification) }
      end

      def convertible? = unresolved.empty?

      def total = findings.size

      def of(classification) = findings.select { |f| f.classification == classification }

      # Machine-readable, for a spec to assert against or a cutover log to
      # keep verbatim.
      def to_h
        {
          total: total,
          counts: counts,
          applied: applied.size,
          findings: findings.map(&:to_h)
        }
      end

      # The explicit MUTATION PLAN: exactly what a mutation would write, in
      # the order it would write it, before anything is written.
      #
      # Separate from `to_s` on purpose. `to_s` answers "what is the state of
      # the data"; this answers "what is about to happen to it", which is the
      # question an operator has to sign off before a production cutover.
      def mutation_plan
        by_kind = convertible.group_by { |f| [f.resource_type, f.classification] }

        lines = ['MUTATION PLAN', '=' * 70]
        lines << "Would INSERT #{convertible.size} SpreePos::ExternalRef row(s):"
        by_kind.sort_by { |(type, classification), _| [type.to_s, classification.to_s] }.each do |(type, classification), rows|
          lines << format('  %-10s %-32s %5d', type, classification, rows.size)
        end

        lines << ''
        lines << 'Would UPDATE   0 rows (a ref that already exists is never touched).'
        lines << 'Would DELETE   0 rows.'
        lines << 'Would TOUCH    0 legacy rows (spree_square_catalog_mappings / _taxon_mappings are read-only here).'

        lines << ''
        lines << "Per connection:"
        convertible.group_by { |f| [f.pos_connection_id, f.pos_connection_merchant_id] }
                   .sort_by { |(id, _), _| id.to_i }
                   .each { |(id, merchant), rows| lines << "  connection #{id} (#{merchant}): #{rows.size} row(s)" }

        lines << ''
        if unresolved.any?
          lines << "WOULD REFUSE: #{unresolved.size} row(s) still need human resolution."
          lines << '  Pass allow_unresolved: true only after reviewing each one.'
        else
          lines << 'No unresolved rows. The mutation would proceed.'
        end

        lines << ''
        lines << "Plan digest: #{plan_digest}"
        lines << '  The migrate task refuses without it: pass B2_CONFIRM_PLAN=<this digest>.'

        lines.join("\n")
      end

      # A short, stable fingerprint of exactly what a mutation would do: the
      # convertible rows it would insert, and the unresolved rows it would
      # leave. Printed by the dry run, and REQUIRED by the migrate task.
      #
      # This is the accidental-trigger guard. Typing the task name is not
      # enough; the operator has to supply the digest of a plan they actually
      # reviewed. And because the Migrator recomputes it from its own fresh
      # analysis, a digest from a stale dry run (data changed since) does
      # not match, so an unreviewed plan can never be applied.
      #
      # Each entry is serialized to JSON before sorting so a nil in one
      # column can never make the sort raise.
      def plan_digest
        canonical = {
          convertible: convertible.map { |f| JSON.generate([f.pos_connection_id, f.resource_type, f.external_id, f.spree_type, f.spree_id, f.external_version]) }.sort,
          unresolved: unresolved.map { |f| JSON.generate([f.classification, f.resource_type, f.external_id]) }.sort
        }
        Digest::SHA256.hexdigest(JSON.generate(canonical))[0, 16]
      end

      def to_s
        lines = ["Legacy catalog reconciliation: #{total} legacy mapping row(s)"]
        Finding::ALL.each do |classification|
          count = counts[classification]
          next if count.zero?

          lines << format('  %-32s %5d', classification, count)
        end
        lines << "  applied: #{applied.size}" if applied.any?
        lines.concat(unresolved_lines)
        lines.join("\n")
      end

      private

      def unresolved_lines
        return [] if unresolved.empty?

        ['', "Needs resolution before cutover (#{unresolved.size}):"] +
          unresolved.map do |f|
            "  [#{f.classification}] #{f.resource_type} #{f.external_id} " \
              "-> #{f.spree_type}##{f.spree_id} " \
              "(#{f.legacy_table}##{f.legacy_id}, connection #{f.pos_connection_id || 'none'}): #{f.detail}"
          end
      end
    end
  end
end
