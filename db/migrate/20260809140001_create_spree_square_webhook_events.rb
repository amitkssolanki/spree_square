class CreateSpreeSquareWebhookEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :spree_square_webhook_events do |t|
      # Square's notification envelope carries its own event_id — the
      # idempotency key. Square retries on a slow/failed ack, so the same
      # event can arrive more than once; the unique index is what makes a
      # duplicate delivery a no-op instead of double-processing.
      t.string :square_event_id, null: false
      t.string :event_type, null: false
      # `json`, not `jsonb`: SQLite (used by the extension's own dummy app
      # for fast specs) has no jsonb type, and nothing here does SQL-level
      # JSON querying — application code only ever reads/writes it as a
      # plain Ruby hash, so the Postgres jsonb-vs-json performance distinction
      # doesn't apply.
      t.json :payload, null: false, default: {}
      t.datetime :processed_at
      t.string :status, null: false, default: 'pending' # pending, processed, failed
      t.text :error_message

      t.timestamps
    end

    add_index :spree_square_webhook_events, :square_event_id, unique: true
    add_index :spree_square_webhook_events, :event_type
  end
end
