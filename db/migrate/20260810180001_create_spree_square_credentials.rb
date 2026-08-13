class CreateSpreeSquareCredentials < ActiveRecord::Migration[8.1]
  def change
    create_table :spree_square_credentials do |t|
      t.references :store, null: false, foreign_key: { to_table: :spree_stores }, index: { unique: true }

      # Encrypted at the application layer (ActiveRecord::Encryption, see
      # SpreeSquare::Credential) — stored as text since encrypted payloads are
      # longer than the plaintext token.
      t.text :access_token
      t.text :refresh_token

      # Square's own merchant identifier — how a webhook payload (which
      # carries merchant_id, not a store id of ours) gets routed back to the
      # right store.
      t.string :square_merchant_id, null: false
      t.string :square_environment, null: false, default: 'sandbox'
      t.datetime :expires_at
      t.datetime :refresh_token_expires_at
      # `t.json`, not `t.jsonb`/`array: true` — the extension's own dummy
      # app (spec/dummy) runs on SQLite, which supports neither.
      #
      # No `default: []` here — MySQL rejects a literal DEFAULT on JSON
      # columns entirely, which canceled every migration after this one in
      # CI's MySQL job. Default now lives on the model instead (see
      # Credential's own `attribute :scopes, default: -> { [] }`) — the
      # :square_credential factory relies on this default (never sets
      # `scopes` explicitly), so this had to move, not just disappear.
      t.json :scopes, null: false

      t.timestamps
    end

    add_index :spree_square_credentials, :square_merchant_id, unique: true
  end
end
