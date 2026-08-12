class CreateSpreeSquareTaxonMappings < ActiveRecord::Migration[8.1]
  def change
    create_table :spree_square_taxon_mappings do |t|
      t.string :square_category_id, null: false
      # References spree_taxons — Spree::Category is an STI subclass sharing
      # that table (see Spree::Category's own comment: it becomes the base
      # class in 6.0, when spree_taxons is renamed to spree_categories).
      t.references :spree_taxon, null: false, foreign_key: { to_table: :spree_taxons }
      t.bigint :square_version

      t.timestamps
    end

    add_index :spree_square_taxon_mappings, :square_category_id, unique: true
  end
end
