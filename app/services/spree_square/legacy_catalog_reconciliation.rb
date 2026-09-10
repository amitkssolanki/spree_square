module SpreeSquare
  # The one-time cutover from this gem's own legacy mapping tables
  # (spree_square_catalog_mappings / spree_square_taxon_mappings) to the
  # provider-neutral SpreePos::ExternalRef table (B2).
  #
  # It lives in spree_square, not spree_pos, for a structural reason rather
  # than a stylistic one: reconciliation has to READ the Square-specific
  # legacy tables, and spree_pos must not know those exist. Every future
  # provider that arrives with its own pre-neutral mapping table brings its
  # own equivalent of this class; nothing here needs to be generalised
  # first.
  #
  # Two strictly separated entry points:
  #
  #   analyze  -> a Report. ZERO writes. Safe to run against production.
  #   migrate! -> a Report plus applied rows. Writes ONLY the findings the
  #               analysis already classified as convertible.
  #
  # The mutation deliberately re-uses the analyzer rather than re-deriving
  # anything of its own, so "what the dry run said" and "what the mutation
  # does" cannot drift apart. Anything the analyzer could not classify as
  # convertible is left completely untouched: no guessing, no winner
  # picked, no legacy row deleted or edited, ever.
  module LegacyCatalogReconciliation
    class << self
      # Report-only. @param connection [SpreePos::Connection, nil] pins
      #   every legacy row to this connection instead of resolving one per
      #   row from the Spree target's own store. Pass it when the legacy
      #   data's owner is known and the store lookup would be ambiguous.
      def analyze(connection: nil)
        Analyzer.new(connection: connection).call
      end

      # Mutating. Must be invoked explicitly; nothing calls it on a
      # schedule, from a webhook, or from catalog sync.
      #
      # REFUSES rather than mutating when a hard invariant fails, including
      # the default refusal on any row still needing human resolution.
      # `allow_unresolved:` lifts only that one check, and only on purpose.
      def migrate!(connection: nil, allow_unresolved: false)
        Migrator.new(connection: connection, allow_unresolved: allow_unresolved).call
      end
    end
  end
end
