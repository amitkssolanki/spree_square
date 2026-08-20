RSpec.describe 'SpreeSquare::CatalogObjectMapper tax handling (Phase 8)' do
  let(:store) { Spree::Store.default }
  let(:mapper) { SpreeSquare::CatalogObjectMapper.new }
  let(:state) { create(:state, name: 'Ohio', abbr: 'OH') }
  let!(:default_stock_location) { create(:stock_location, default: true, state: state, country: state.country) }
  let!(:tax_zone) { create(:zone, name: 'OH Sales Tax', kind: 'state').tap { |z| z.members.create!(zoneable: state) } }

  # Mirrors catalog_object_mapper_spec.rb's own `square_object` helper
  # exactly (see its comment for why this is a plain double, not
  # instance_double).
  def square_object(id:, type:, version: 1, **data_by_key)
    data_key = "#{type.downcase}_data"
    double(
      "Square::Types::CatalogObject(#{type})",
      id: id,
      type: type,
      version: version,
      **{ data_key.to_sym => OpenStruct.new(data_by_key[data_key.to_sym] || {}) }
    )
  end

  def tax_object(id:, name:, percentage:, version: 1, enabled: true, inclusion_type: 'ADDITIVE')
    square_object(
      id: id, type: 'TAX', version: version,
      tax_data: { name: name, percentage: percentage, enabled: enabled, inclusion_type: inclusion_type }
    )
  end

  def item_object(id:, name:, tax_ids: [], version: 1)
    square_object(
      id: id, type: 'ITEM', version: version,
      item_data: { name: name, description: nil, variations: [], image_ids: nil, category_id: nil,
                   categories: nil, modifier_list_info: nil, tax_ids: tax_ids }
    )
  end

  before do
    Spree::ShippingCategory.find_or_create_by!(name: 'Default')
    Spree::Channel.find_or_create_by!(code: 'online') { |c| c.name = 'Online Store'; c.store = store }
  end

  describe '#map_tax' do
    it 'creates a SpreeSquare::TaxMapping mirroring the Square percentage/inclusion' do
      mapper.map_tax(tax_object(id: 'sq_tax_1', name: 'Sales Tax', percentage: '8.0'))

      mapping = SpreeSquare::TaxMapping.find_by(square_tax_id: 'sq_tax_1')
      expect(mapping.name).to eq('Sales Tax')
      expect(mapping.percentage).to eq(8.0)
      expect(mapping.included_in_price).to be false
      expect(mapping.enabled).to be true
    end

    it 'does not create a Spree::TaxRate until an item actually references the tax' do
      mapper.map_tax(tax_object(id: 'sq_tax_1', name: 'Sales Tax', percentage: '8.0'))

      expect(Spree::TaxRate.count).to eq(0)
    end

    it 're-syncing an already-materialized tax updates its Spree::TaxRate amount in place' do
      mapper.map_tax(tax_object(id: 'sq_tax_1', name: 'Sales Tax', percentage: '8.0'))
      mapper.map_item(item_object(id: 'sq_item_1', name: 'Nachos', tax_ids: ['sq_tax_1']))
      rate = Spree::TaxRate.last
      expect(rate.amount).to eq(0.08)

      mapper.map_tax(tax_object(id: 'sq_tax_1', name: 'Sales Tax', percentage: '9.5', version: 2))

      expect(rate.reload.amount).to eq(0.095)
    end

    it 'disabling the tax in Square soft-deletes every Spree::TaxRate it backs; re-enabling restores them' do
      mapper.map_tax(tax_object(id: 'sq_tax_1', name: 'Sales Tax', percentage: '8.0'))
      mapper.map_item(item_object(id: 'sq_item_1', name: 'Nachos', tax_ids: ['sq_tax_1']))
      rate = Spree::TaxRate.last

      mapper.map_tax(tax_object(id: 'sq_tax_1', name: 'Sales Tax', percentage: '8.0', enabled: false, version: 2))
      expect(Spree::TaxRate.unscoped.find(rate.id).deleted_at).to be_present
      expect(Spree::TaxRate.count).to eq(0)

      mapper.map_tax(tax_object(id: 'sq_tax_1', name: 'Sales Tax', percentage: '8.0', enabled: true, version: 3))
      expect(rate.reload.deleted_at).to be_nil
      expect(Spree::TaxRate.count).to eq(1)
    end
  end

  describe '#map_item — tax_category resolution' do
    it 'an item with no tax_ids resolves to the Non-taxable category' do
      product = mapper.map_item(item_object(id: 'sq_item_1', name: 'Water', tax_ids: []))

      expect(product.tax_category.name).to eq('Non-taxable')
    end

    it 'an item referencing an unknown/unsynced tax id falls back to Non-taxable rather than raising' do
      product = mapper.map_item(item_object(id: 'sq_item_1', name: 'Mystery Item', tax_ids: ['not_a_real_tax']))

      expect(product.tax_category.name).to eq('Non-taxable')
    end

    it 'an item with one known tax resolves to a category backed by exactly one Spree::TaxRate at the right amount' do
      mapper.map_tax(tax_object(id: 'sq_tax_1', name: 'Sales Tax', percentage: '8.0'))
      product = mapper.map_item(item_object(id: 'sq_item_1', name: 'Nachos', tax_ids: ['sq_tax_1']))

      category = product.tax_category
      expect(category.name).not_to eq('Non-taxable')
      rates = Spree::TaxRate.where(tax_category: category)
      expect(rates.count).to eq(1)
      expect(rates.first.amount).to eq(0.08)
      expect(rates.first.zone).to eq(tax_zone)
    end

    it 'two items sharing the exact same single tax resolve to the SAME category (no duplicate categories/rates)' do
      mapper.map_tax(tax_object(id: 'sq_tax_1', name: 'Sales Tax', percentage: '8.0'))
      a = mapper.map_item(item_object(id: 'sq_item_1', name: 'Nachos', tax_ids: ['sq_tax_1']))
      b = mapper.map_item(item_object(id: 'sq_item_2', name: 'Wings', tax_ids: ['sq_tax_1']))

      expect(a.tax_category_id).to eq(b.tax_category_id)
      expect(Spree::TaxCategory.count).to eq(1)
      expect(Spree::TaxRate.count).to eq(1)
    end

    it 'an item carrying two stacked taxes gets its own composite category with two rates, distinct from either tax alone' do
      mapper.map_tax(tax_object(id: 'sq_tax_1', name: 'Sales Tax', percentage: '8.0'))
      mapper.map_tax(tax_object(id: 'sq_tax_2', name: 'Bottle Tax', percentage: '1.0'))
      solo = mapper.map_item(item_object(id: 'sq_item_1', name: 'Nachos', tax_ids: ['sq_tax_1']))
      stacked = mapper.map_item(item_object(id: 'sq_item_2', name: 'Soda', tax_ids: %w[sq_tax_1 sq_tax_2]))

      expect(stacked.tax_category_id).not_to eq(solo.tax_category_id)
      stacked_rates = Spree::TaxRate.where(tax_category: stacked.tax_category)
      expect(stacked_rates.pluck(:amount)).to contain_exactly(0.08, 0.01)
      # The solo category from before is untouched — still exactly one rate.
      expect(Spree::TaxRate.where(tax_category: solo.tax_category).count).to eq(1)
    end
  end
end
