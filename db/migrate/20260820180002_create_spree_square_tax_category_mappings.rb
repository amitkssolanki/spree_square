class CreateSpreeSquareTaxCategoryMappings < ActiveRecord::Migration[8.1]
  def change
    # A single Square tax can back tax rates in more than one Spree tax
    # category — e.g. item A carries only "Sales Tax", item B carries
    # "Sales Tax" + "Bottle Tax" together, so "Sales Tax" needs its own
    # Spree::TaxRate under each of the two resulting composite categories.
    # This join records, for one (tax_category, square tax) pair, which
    # Spree::TaxRate row represents it — the lookup CatalogObjectMapper
    # uses to find-or-create the right composite Spree::TaxCategory for an
    # item's exact set of Square tax ids, without any schema change to
    # core's spree_tax_categories/spree_tax_rates tables.
    create_table :spree_square_tax_category_mappings do |t|
      t.references :tax_category, null: false, foreign_key: { to_table: :spree_tax_categories }
      t.references :tax_mapping, null: false, foreign_key: { to_table: :spree_square_tax_mappings }
      t.references :tax_rate, null: false, foreign_key: { to_table: :spree_tax_rates }

      t.timestamps
    end

    add_index :spree_square_tax_category_mappings, %i[tax_category_id tax_mapping_id],
              unique: true, name: 'index_square_tax_category_mappings_on_category_and_tax'
  end
end
