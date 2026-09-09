# Characterization spec, written in Phase 0 before this serializer moves
# anywhere (Phase 2, sequence step 12d). Covers the two behaviours the plan
# calls out by name: the modifier_lists attribute, and the Spree::Category
# taxonomy fix — a regression in the latter 500s every product detail page
# on the storefront, since the Next.js PDP always requests expand=categories.
#
# Alba stringifies the keys it generates for a resource's own declared
# attributes (top-level keys here, and nested keys from a nested Alba
# resource like `categories`), but a raw Hash literal returned as an
# attribute's *value* — `modifier_lists` and `square_modifiers`'s per-item
# hashes below — passes through exactly as written, with symbol keys.
RSpec.describe SpreeSquare::ProductSerializer do
  let(:store) { Spree::Store.default }
  let(:product) { create(:product, store: store) }

  def serialize(params = {})
    described_class.new(product, params: { store: store }.merge(params)).serializable_hash
  end

  describe 'modifier_lists' do
    it 'is empty when the product has no modifier lists attached' do
      expect(serialize['modifier_lists']).to eq([])
    end

    it 'exposes an attached modifier list with its modifiers, keyed by Square ids' do
      list = SpreeSquare::ModifierList.create!(square_modifier_list_id: 'sq_list_1', name: 'Milk', selection_type: 'SINGLE',
                                                min_selected_modifiers: 0, max_selected_modifiers: 1)
      modifier = SpreeSquare::Modifier.create!(modifier_list: list, square_modifier_id: 'sq_mod_1', name: 'Oat milk', price_cents: 75)
      SpreeSquare::ProductModifierList.create!(product: product, modifier_list: list)

      result = serialize['modifier_lists']

      expect(result.size).to eq(1)
      expect(result.first).to include(
        id: 'sq_list_1', name: 'Milk', selection_type: 'SINGLE',
        min_selected_modifiers: 0, max_selected_modifiers: 1
      )
      expect(result.first[:modifiers]).to eq([{ id: 'sq_mod_1', name: 'Oat milk', price_cents: 75, display_price: modifier.price }])
    end
  end

  describe 'categories (the Spree::Category-without-taxonomy fix)' do
    # Spree::Category is the store-scoped, taxonomy-free Taxon subclass this
    # catalog uses exclusively (see its own comment). Core's `categories`
    # field assumes every taxon has a taxonomy and calls
    # `t.taxonomy.store_id`, which raises NoMethodError on nil for a Category
    # — this serializer re-declares the field to fall back to the taxon's own
    # store_id when there is no taxonomy.
    let(:category) { Spree::Category.create!(name: 'Beverages', store: store) }

    before { product.taxons << category }

    it 'does not raise for a taxonomy-free Spree::Category when categories are expanded' do
      expect { serialize(expand: ['categories']) }.not_to raise_error
    end

    it 'includes the category under the categories key' do
      result = serialize(expand: ['categories'])

      expect(result['categories'].map { |c| c['name'] }).to include('Beverages')
    end

    it 'omits categories entirely when not expanded (the default)' do
      result = serialize

      expect(result).not_to have_key('categories')
    end

    it 'excludes a category belonging to a different store' do
      other_store = create(:store)
      other_category = Spree::Category.create!(name: 'Other Brand Menu', store: other_store)
      product.taxons << other_category

      result = serialize(expand: ['categories'])

      expect(result['categories'].map { |c| c['name'] }).not_to include('Other Brand Menu')
    end
  end
end
