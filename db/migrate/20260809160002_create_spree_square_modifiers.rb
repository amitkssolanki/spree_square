class CreateSpreeSquareModifiers < ActiveRecord::Migration[8.1]
  def change
    create_table :spree_square_modifiers do |t|
      t.references :modifier_list, null: false, foreign_key: { to_table: :spree_square_modifier_lists }
      t.string :square_modifier_id, null: false
      t.string :name, null: false
      t.integer :price_cents, null: false, default: 0
      t.bigint :square_version

      t.timestamps
    end

    add_index :spree_square_modifiers, :square_modifier_id, unique: true
  end
end
