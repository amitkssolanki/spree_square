# Characterization spec, written in Phase 0 before this service moves
# anywhere (Phase 2, sequence step 12c). Covers the two subtleties the class
# comment calls out: the `prepend Spree::ServiceModule::Base` re-prepend
# (without it, `run` blows up on a nil `@_passed_input` before this class
# ever gets a chance to run) and the double `recalculate_price` call being
# what makes the *response* reflect the final, modifier-adjusted price
# rather than just the persisted row eventually catching up.
#
# The final `run Spree.cart_recalculate_service` step returns its own
# success(line_item) — a bare Spree::LineItem, not the {order:, line_item:,
# ...} hash the earlier steps pass along — so `result.value` here is the
# line item itself, not a hash to index into.
RSpec.describe SpreeSquare::Cart::AddItem do
  let(:order) { create(:order, currency: 'USD') }
  let(:variant) { create(:variant, price: 10.00) }
  let(:modifier_list) { SpreeSquare::ModifierList.create!(square_modifier_list_id: 'sq_list_1', name: 'Extras', selection_type: 'MULTIPLE') }
  let!(:modifier) { SpreeSquare::Modifier.create!(modifier_list: modifier_list, square_modifier_id: 'sq_mod_1', name: 'Extra cheese', price_cents: 150) }

  it 'does not raise on @_passed_input — the re-prepend is load-bearing' do
    expect do
      described_class.call(order: order, variant: variant)
    end.not_to raise_error
  end

  it 'creates a line item with no modifiers when none are selected' do
    result = described_class.call(order: order, variant: variant)

    expect(result).to be_success
    expect(result.value.variant).to eq(variant)
    expect(SpreeSquare::LineItemModifier.count).to eq(0)
  end

  it 'creates a persistent LineItemModifier snapshot for each selected modifier' do
    result = described_class.call(order: order, variant: variant, options: { square_modifier_ids: ['sq_mod_1'] })

    lim = SpreeSquare::LineItemModifier.find_by(line_item: result.value)
    expect(lim.square_modifier_id).to eq('sq_mod_1')
    expect(lim.name_snapshot).to eq('Extra cheese')
    expect(lim.price_cents_snapshot).to eq(150)
  end

  it 'the response price already reflects the modifier delta, not just the eventually-persisted row' do
    result = described_class.call(order: order, variant: variant, options: { square_modifier_ids: ['sq_mod_1'] })

    expect(result.value.price.to_f).to eq(11.50)
  end

  it 'does not attach modifiers a second time when adding the same variant+modifiers again (quantity bump, not a new snapshot set)' do
    described_class.call(order: order, variant: variant, options: { square_modifier_ids: ['sq_mod_1'] })
    result = described_class.call(order: order, variant: variant, options: { square_modifier_ids: ['sq_mod_1'] })

    expect(order.reload.line_items.where(variant: variant).count).to eq(1)
    expect(result.value.quantity).to eq(2)
    expect(SpreeSquare::LineItemModifier.count).to eq(1)
  end

  it 'keeps two differently-modified selections of the same variant as separate line items (via the custom finder)' do
    described_class.call(order: order, variant: variant, options: { square_modifier_ids: ['sq_mod_1'] })
    described_class.call(order: order, variant: variant, options: {})

    expect(order.reload.line_items.where(variant: variant).count).to eq(2)
  end
end
