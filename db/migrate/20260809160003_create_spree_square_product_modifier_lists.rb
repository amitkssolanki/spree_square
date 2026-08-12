class CreateSpreeSquareProductModifierLists < ActiveRecord::Migration[8.1]
  def change
    create_table :spree_square_product_modifier_lists do |t|
      t.references :product, null: false, foreign_key: { to_table: :spree_products }
      t.references :modifier_list, null: false, foreign_key: { to_table: :spree_square_modifier_lists }

      t.timestamps
    end

    add_index :spree_square_product_modifier_lists, %i[product_id modifier_list_id],
              unique: true, name: 'index_square_product_modifier_lists_uniq'
  end
end
