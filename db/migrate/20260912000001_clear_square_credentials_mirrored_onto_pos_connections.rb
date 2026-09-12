class ClearSquareCredentialsMirroredOntoPosConnections < ActiveRecord::Migration[8.1]
  # Phase 3's absorb migration copied the Square credential onto
  # SpreePos::Connection (access token, refresh token, both expiries, the
  # webhook secret) so a future release could make the connection the
  # credential's home for every provider. That move has not happened for
  # Square: SpreeSquare::Client reads SpreeSquare::Credential, the admin OAuth
  # flow writes it, and the automatic refresh updates it. Nothing reads the
  # connection's copy.
  #
  # So the copy only drifts. Verified in production on 2026-09-12: the first
  # automatic refresh updated the credential (new token, expiry 2026-10-12)
  # and left the connection holding the pre-refresh token and the old expiry.
  # A stale token nobody reads is a trap for the next person who reads it.
  #
  # This clears the mirrored credential material from Square connections,
  # leaving exactly one authoritative source. `scopes` and `connected_at`
  # stay: they describe the connection itself, not the secret.
  #
  # Clover is untouched. Its connections ARE the credential's home
  # (SpreeClover::Client reads connection.access_token), which is the shape
  # Square is expected to adopt later; when it does, that migration moves the
  # credential the other way, from SpreeSquare::Credential onto the
  # connection, and this one becomes irrelevant rather than wrong.
  MIRRORED_COLUMNS = %w[access_token refresh_token expires_at refresh_token_expires_at webhook_secret].freeze

  def up
    return unless table_exists?(:spree_pos_connections) && table_exists?(:spree_square_credentials)

    select_all(<<~SQL.squish).each do |row|
      SELECT c.id, c.store_id,
             (SELECT COUNT(*) FROM spree_square_credentials s WHERE s.store_id = c.store_id) AS credentials
      FROM spree_pos_connections c
      WHERE c.provider = 'square'
    SQL
      # Only ever clear a copy: never the last one. A Square connection whose
      # store has no SpreeSquare::Credential would be holding the only
      # credential there is, so it is left alone and reported.
      if row['credentials'].to_i.zero?
        say "connection #{row['id']}: store #{row['store_id']} has no SpreeSquare::Credential, leaving its credential columns alone", true
        next
      end

      execute(<<~SQL.squish)
        UPDATE spree_pos_connections
        SET #{MIRRORED_COLUMNS.map { |column| "#{column} = NULL" }.join(', ')}, updated_at = CURRENT_TIMESTAMP
        WHERE id = #{row['id'].to_i}
      SQL
      say "connection #{row['id']}: cleared the credential mirrored from SpreeSquare::Credential", true
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'The cleared values were a stale copy of SpreeSquare::Credential; reconnect Square to repopulate a connection.'
  end
end
