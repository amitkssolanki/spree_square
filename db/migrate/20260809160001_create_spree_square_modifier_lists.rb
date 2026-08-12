class CreateSpreeSquareModifierLists < ActiveRecord::Migration[8.1]
  def change
    create_table :spree_square_modifier_lists do |t|
      t.string :square_modifier_list_id, null: false
      t.string :name, null: false
      t.string :selection_type, null: false, default: 'SINGLE' # SINGLE or MULTIPLE
      t.integer :min_selected_modifiers
      t.integer :max_selected_modifiers
      t.bigint :square_version

      t.timestamps
    end

    add_index :spree_square_modifier_lists, :square_modifier_list_id, unique: true
  end
end
