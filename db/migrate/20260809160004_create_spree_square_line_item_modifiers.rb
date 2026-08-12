class CreateSpreeSquareLineItemModifiers < ActiveRecord::Migration[8.1]
  def change
    create_table :spree_square_line_item_modifiers do |t|
      t.references :line_item, null: false, foreign_key: { to_table: :spree_line_items }
      # Nullable + snapshot columns: if the Modifier record is later deleted
      # (menu edit in Square), a past order must still show and total exactly
      # what the customer paid for, unaffected by any later catalog change.
      t.references :modifier, null: true, foreign_key: { to_table: :spree_square_modifiers }
      t.string :square_modifier_id
      t.string :name_snapshot, null: false
      t.integer :price_cents_snapshot, null: false, default: 0

      t.timestamps
    end
  end
end
