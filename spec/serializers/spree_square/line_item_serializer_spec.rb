# Characterization spec, written in Phase 0 before this serializer moves
# anywhere (Phase 2, sequence step 12d). This is the storefront's
# square_modifiers contract (src/lib/utils/line-item-modifiers.ts on the
# Next.js side) — a regression here silently breaks cart/checkout modifier
# display across a deploy boundary that crosses two repositories.
RSpec.describe SpreeSquare::LineItemSerializer do
  let(:line_item) { create(:line_item) }

  def serialize
    described_class.new(line_item).serializable_hash
  end

  it 'is empty when the line item has no modifiers selected' do
    expect(serialize['square_modifiers']).to eq([])
  end

  it 'exposes the snapshot recorded at add-to-cart time, not a live modifier lookup' do
    modifier = SpreeSquare::Modifier.create!(
      modifier_list: SpreeSquare::ModifierList.create!(square_modifier_list_id: 'sq_list_1', name: 'Milk', selection_type: 'SINGLE'),
      square_modifier_id: 'sq_mod_1', name: 'Oat milk', price_cents: 75
    )
    SpreeSquare::LineItemModifier.create!(
      line_item: line_item, modifier: modifier, square_modifier_id: modifier.square_modifier_id,
      name_snapshot: modifier.name, price_cents_snapshot: modifier.price_cents
    )

    expect(serialize['square_modifiers']).to eq([{ name: 'Oat milk', price_cents: 75, display_price: 0.75 }])
  end

  it 'keeps showing the snapshot after the live Square modifier is renamed/repriced' do
    modifier = SpreeSquare::Modifier.create!(
      modifier_list: SpreeSquare::ModifierList.create!(square_modifier_list_id: 'sq_list_1', name: 'Milk', selection_type: 'SINGLE'),
      square_modifier_id: 'sq_mod_1', name: 'Oat milk', price_cents: 75
    )
    SpreeSquare::LineItemModifier.create!(
      line_item: line_item, modifier: modifier, square_modifier_id: modifier.square_modifier_id,
      name_snapshot: modifier.name, price_cents_snapshot: modifier.price_cents
    )

    modifier.update!(name: 'Oat milk (large)', price_cents: 150)

    expect(serialize['square_modifiers']).to eq([{ name: 'Oat milk', price_cents: 75, display_price: 0.75 }])
  end

  it 'still shows the snapshot when the LineItemModifier has no live modifier reference at all' do
    # `modifier: optional` on the model reads as "a past order survives a
    # later Square menu edit deleting the Modifier row" (see the model's own
    # comment) — but the migration puts no ON DELETE behavior on the FK, so
    # in the *current* schema a referenced Modifier can't actually be
    # destroyed (confirmed: it raises ActiveRecord::InvalidForeignKey, not
    # asserted here since it's not what this serializer is about). What the
    # serializer itself guarantees, and what's characterized here, is that
    # it only ever reads the snapshot columns — a LineItemModifier built
    # with no modifier reference at all serializes identically.
    SpreeSquare::LineItemModifier.create!(
      line_item: line_item, modifier: nil, square_modifier_id: 'sq_mod_1',
      name_snapshot: 'Oat milk', price_cents_snapshot: 75
    )

    expect(serialize['square_modifiers']).to eq([{ name: 'Oat milk', price_cents: 75, display_price: 0.75 }])
  end
end
