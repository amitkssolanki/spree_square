class CreateSpreeSquareOrderMappings < ActiveRecord::Migration[8.1]
  def change
    create_table :spree_square_order_mappings do |t|
      t.references :spree_order, null: false, foreign_key: { to_table: :spree_orders }, index: { unique: true }
      t.string :square_order_id
      t.string :square_payment_id
      t.string :square_location_id
      t.bigint :square_version
      t.string :last_status
      t.text :push_error

      t.timestamps
    end

    add_index :spree_square_order_mappings, :square_order_id, unique: true
  end
end
