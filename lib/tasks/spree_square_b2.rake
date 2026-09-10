# B2: the one-time cutover from this gem's legacy mapping tables to the
# provider-neutral SpreePos::ExternalRef table. See
# docs/plans/b2-externalref-cutover-plan.md for the procedure these two
# tasks exist to serve.
#
# The split is deliberate and is the whole safety story: `dry_run` is
# read-only and safe to run against production at any time, `migrate` is
# the only thing that writes and has to be typed out on purpose.
namespace :spree_square do
  namespace :b2 do
    desc 'REPORT ONLY. Classify every legacy catalog/taxon mapping against SpreePos::ExternalRef. Writes nothing.'
    task dry_run: :environment do
      report = SpreeSquare::LegacyCatalogReconciliation.analyze(connection: b2_connection)
      puts report
      puts
      # The explicit plan an operator signs off before a production cutover:
      # what would be written, per resource type and per connection, and what
      # would deliberately not be touched.
      puts report.mutation_plan

      # Non-zero on anything a human still has to decide, so a cutover
      # script cannot proceed past an unresolved conflict by accident.
      # `unchanged` and `already_represented` are not failures: they are
      # what a re-run of a completed migration looks like.
      exit(1) if report.unresolved.any?
    end

    desc 'MUTATES. Create SpreePos::ExternalRef rows for every convertible legacy mapping. Idempotent.'
    # ALLOW_UNRESOLVED=1 migrates the convertible rows while leaving
    # unresolved ones alone. Deliberately an environment variable that has to
    # be typed: the default refuses, because unresolved rows mean a human has
    # not finished deciding.
    task migrate: :environment do
      report = SpreeSquare::LegacyCatalogReconciliation.migrate!(
        connection: b2_connection,
        allow_unresolved: ENV['ALLOW_UNRESOLVED'].present?
      )
      puts report
      puts "\nApplied #{report.applied.size} ExternalRef row(s)."
      puts "Left unresolved: #{report.unresolved.size} row(s). Nothing was overwritten and no legacy row was touched."
    end
  end
end

# Optional: POS_CONNECTION_ID pins every legacy row to one connection
# instead of resolving one per row from the Spree record's own store. Use
# it only when the store lookup is ambiguous and the true owner is known.
def b2_connection
  id = ENV['POS_CONNECTION_ID']
  return nil if id.blank?

  SpreePos::Connection.find(id)
end
