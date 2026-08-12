class CreateSpreeSquareCatalogMappings < ActiveRecord::Migration[8.1]
  def change
    create_table :spree_square_catalog_mappings do |t|
      t.string :square_catalog_object_id, null: false
      # "item" or "item_variation" — which Square object this row mirrors.
      t.string :square_object_type, null: false
      t.references :spree_product, null: true, foreign_key: { to_table: :spree_products }
      t.references :spree_variant, null: true, foreign_key: { to_table: :spree_variants }
      # Square's optimistic-concurrency token. Compared before writing so a
      # webhook that arrives out of order (or a duplicate) can't clobber a
      # newer state with older data.
      t.bigint :square_version
      t.datetime :last_synced_at

      t.timestamps
    end

    add_index :spree_square_catalog_mappings, :square_catalog_object_id, unique: true
  end
end
