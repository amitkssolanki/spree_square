class CreateSpreeSquareLocationMappings < ActiveRecord::Migration[8.1]
  def change
    create_table :spree_square_location_mappings do |t|
      t.string :square_location_id, null: false
      t.references :spree_stock_location, null: false, foreign_key: { to_table: :spree_stock_locations }

      t.timestamps
    end

    add_index :spree_square_location_mappings, :square_location_id, unique: true
  end
end
