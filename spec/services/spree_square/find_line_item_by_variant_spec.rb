# Characterization spec, written in Phase 0. Spree::LineItems::FindByVariant
# matches purely on variant_id and calls Spree.cart_compare_line_items_service
# but discards the result — customizing that comparator alone was verified
# live to have no effect, which is why this finder replaces the matching
# logic itself rather than trying to plug into the comparator hook.
RSpec.describe SpreeSquare::FindLineItemByVariant do
  let(:order) { create(:order) }
  let(:variant) { create(:variant) }
  let(:finder) { described_class.new }

  def line_item_with_modifiers(*square_modifier_ids)
    line_item = create(:line_item, order: order, variant: variant)
    square_modifier_ids.each do |id|
      SpreeSquare::LineItemModifier.create!(line_item: line_item, square_modifier_id: id, name_snapshot: id, price_cents_snapshot: 0)
    end
    line_item
  end

  it 'matches an existing line item with no modifiers when none are requested' do
    existing = line_item_with_modifiers

    found = finder.execute(order: order, variant: variant, options: {})

    expect(found).to eq(existing)
  end

  it 'does not match a plain (no-modifier) line item when modifiers are requested' do
    line_item_with_modifiers

    found = finder.execute(order: order, variant: variant, options: { square_modifier_ids: ['sq_mod_1'] })

    expect(found).to be_nil
  end

  it 'matches an existing line item whose modifier set is exactly the same, regardless of order' do
    existing = line_item_with_modifiers('sq_mod_2', 'sq_mod_1')

    found = finder.execute(order: order, variant: variant, options: { square_modifier_ids: ['sq_mod_1', 'sq_mod_2'] })

    expect(found).to eq(existing)
  end

  it 'does NOT merge two line items of the same variant with different modifier selections' do
    cheese = line_item_with_modifiers('sq_extra_cheese')
    line_item_with_modifiers('sq_no_cheese')

    found = finder.execute(order: order, variant: variant, options: { square_modifier_ids: ['sq_extra_cheese'] })

    expect(found).to eq(cheese)
  end

  it 'accepts string-keyed options (as arrive from the Store API JSON body)' do
    existing = line_item_with_modifiers('sq_mod_1')

    found = finder.execute(order: order, variant: variant, options: { 'square_modifier_ids' => ['sq_mod_1'] })

    expect(found).to eq(existing)
  end

  it 'returns nil when nothing on the order matches this variant at all' do
    other_variant = create(:variant)
    create(:line_item, order: order, variant: other_variant)

    found = finder.execute(order: order, variant: variant, options: {})

    expect(found).to be_nil
  end
end
