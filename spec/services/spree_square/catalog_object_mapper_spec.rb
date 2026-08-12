RSpec.describe SpreeSquare::CatalogObjectMapper do
  let(:store) { Spree::Store.default }
  let(:mapper) { described_class.new }

  # Minimal stand-ins for the Square SDK's typed response objects — real
  # payload shapes for these were verified against the live sandbox in
  # M2/M3; this spec is about our own mapping decisions, not re-verifying
  # Square's wire format. A plain double, not instance_double: Square's
  # CatalogObject is a discriminated union (Fern-generated) whose member
  # classes define fields dynamically — verifying doubles against it proved
  # order-dependent (passed in isolation, failed as part of the full suite,
  # depending on which concrete member class Zeitwerk had already
  # autoloaded), which is exactly the kind of flakiness a verifying double
  # is supposed to prevent, not cause.
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

  before do
    Spree::ShippingCategory.find_or_create_by!(name: 'Default')
    Spree::Channel.find_or_create_by!(code: 'online') { |c| c.name = 'Online Store'; c.store = store }
  end

  describe '#map_item with a single variation' do
    let(:item) do
      square_object(
        id: 'sq_item_1', type: 'ITEM',
        item_data: { name: 'Margherita Pizza', description: 'Classic', variations: [], image_ids: nil, category_id: nil, categories: nil, modifier_list_info: nil }
      )
    end

    it 'creates a Spree::Product' do
      product = mapper.map_item(item)

      expect(product).to be_a(Spree::Product)
      expect(product.name).to eq('Margherita Pizza')
      expect(product.slug).to eq('margherita-pizza-sq_item_1')
    end

    it 'publishes it to the Online Store channel' do
      product = mapper.map_item(item)

      expect(product.product_publications.exists?).to be true
    end

    it 'records a CatalogMapping for the item' do
      product = mapper.map_item(item)
      mapping = SpreeSquare::CatalogMapping.find_by(square_catalog_object_id: 'sq_item_1')

      expect(mapping.square_object_type).to eq(SpreeSquare::CatalogMapping::ITEM)
      expect(mapping.product).to eq(product)
    end

    it 're-syncing the same item updates it in place rather than duplicating it' do
      first = mapper.map_item(item)
      updated_item = square_object(
        id: 'sq_item_1', type: 'ITEM', version: 2,
        item_data: { name: 'Margherita Pizza (Updated)', description: 'Classic', variations: [], image_ids: nil, category_id: nil, categories: nil, modifier_list_info: nil }
      )

      second = mapper.map_item(updated_item)

      expect(second.id).to eq(first.id)
      expect(second.reload.name).to eq('Margherita Pizza (Updated)')
      expect(Spree::Product.where(slug: first.slug).count).to eq(1)
    end
  end

  describe '#map_variation — the master-vs-real-variant decision' do
    # The :product factory auto-assigns a master SKU; our real code path
    # (via #map_item, never exercised by this describe block in isolation)
    # never sets one until the first variation syncs — a blank master SKU
    # is exactly the signal #map_variation uses to decide "reuse master."
    let(:product) { create(:product).tap { |p| p.master.update_column(:sku, '') } }

    def variation(id:, name:, amount:, version: 1)
      square_object(
        id: id, type: 'ITEM_VARIATION', version: version,
        item_variation_data: { name: name, pricing_type: 'FIXED_PRICING', price_money: OpenStruct.new(amount: amount, currency: 'USD') }
      )
    end

    it 'the first variation reuses the product\'s master variant (no OptionType created)' do
      variant = mapper.map_variation(variation(id: 'sq_var_1', name: 'Regular', amount: 1495), product)

      expect(variant).to eq(product.master)
      expect(variant.sku).to eq('sq_var_1')
      expect(variant.price).to eq(14.95)
      expect(Spree::OptionType.where(name: SpreeSquare::CatalogObjectMapper::VARIATION_OPTION_TYPE_NAME)).to be_empty
    end

    it 'a second variation creates a real non-master variant with an option value' do
      mapper.map_variation(variation(id: 'sq_var_1', name: 'Regular', amount: 1495), product)
      second = mapper.map_variation(variation(id: 'sq_var_2', name: 'Large', amount: 1895), product)

      expect(second).not_to eq(product.master)
      expect(second.is_master).to be false
      expect(second.option_values.map(&:presentation)).to include('Large')
      expect(second.price).to eq(18.95)
    end
  end
end
