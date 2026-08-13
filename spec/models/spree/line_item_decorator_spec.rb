RSpec.describe Spree::LineItem, type: :model do
  # Regression test: removing a cart line item that has modifier selections
  # raised ActiveRecord::InvalidForeignKey (Postgres RESTRICT on
  # spree_square_line_item_modifiers.line_item_id) instead of actually
  # removing it. Nothing caught this before a real modifier-bearing item was
  # added to a cart and then removed on the live storefront — every existing
  # spec exercised modifiers in isolation, never a real add-then-remove
  # round trip through Spree::LineItem itself.
  describe 'destroying a line item with modifier selections' do
    it 'removes both the line item and its modifier snapshots, without raising' do
      order = create(:order)
      line_item = create(:line_item, order: order)
      modifier_list = SpreeSquare::ModifierList.create!(
        square_modifier_list_id: 'sq_list_1', name: 'Choose Your Base', selection_type: 'SINGLE'
      )
      modifier = SpreeSquare::Modifier.create!(
        square_modifier_id: 'sq_mod_1', modifier_list: modifier_list, name: 'Quinoa', price_cents: 100
      )
      SpreeSquare::LineItemModifier.build_from(modifier).tap { |lim| lim.line_item = line_item }.save!

      expect { line_item.destroy! }.not_to raise_error

      expect(Spree::LineItem.where(id: line_item.id)).not_to exist
      expect(SpreeSquare::LineItemModifier.where(line_item_id: line_item.id)).not_to exist
    end
  end
end
