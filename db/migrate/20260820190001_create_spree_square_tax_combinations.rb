class CreateSpreeSquareTaxCombinations < ActiveRecord::Migration[8.1]
  def change
    # Resolves the race `create_composite_tax_category!` used to have: two
    # concurrent imports (this rake task's own CatalogImporter.call racing a
    # real catalog.version.updated webhook Square fires back mid-run —
    # confirmed live against production, never exercised by sandbox/local
    # dev with no registered webhook) each finding "no matching category
    # yet" and independently creating one. `signature` is a unique,
    # deterministic key for one exact combination of Square tax ids
    # (sorted, joined) — `create_or_find_by!` against it is a portable
    # (Postgres/MySQL/SQLite) race-safe find-or-create, unlike a
    # Postgres-only advisory lock.
    create_table :spree_square_tax_combinations do |t|
      t.string :signature, null: false
      t.references :tax_category, null: false, foreign_key: { to_table: :spree_tax_categories }

      t.timestamps
    end

    add_index :spree_square_tax_combinations, :signature, unique: true
  end
end
