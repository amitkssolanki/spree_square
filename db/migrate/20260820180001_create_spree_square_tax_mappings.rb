class CreateSpreeSquareTaxMappings < ActiveRecord::Migration[8.1]
  def change
    create_table :spree_square_tax_mappings do |t|
      t.string :square_tax_id, null: false
      t.string :name
      # Mirrors what Square itself stores: a plain decimal percentage
      # (e.g. 8.0, not 0.08) — kept alongside the derived Spree::TaxRate(s)
      # so re-imports can detect a no-op without re-deriving from a rate.
      t.decimal :percentage, precision: 8, scale: 5
      t.boolean :included_in_price, default: false, null: false
      t.boolean :enabled, default: true, null: false
      # Square's optimistic-concurrency token — same stale-check pattern as
      # CatalogMapping, guards against out-of-order webhook delivery.
      t.bigint :square_version
      t.datetime :last_synced_at

      t.timestamps
    end

    add_index :spree_square_tax_mappings, :square_tax_id, unique: true
  end
end
