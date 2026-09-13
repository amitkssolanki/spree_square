RSpec.describe SpreeSquare::CatalogObjectMapper do
  let(:store) { Spree::Store.default }
  let(:mapper) { described_class.new(connection: pos_connection) }

  # Real square.rb objects (spec/support/square_catalog_objects.rb), never
  # doubles: a double answers any method, which is how a field Square does
  # not send reached production on 2026-09-11.
  def square_object(id:, type:, version: 1, **data_by_key)
    square_catalog_object(id: id, type: type, version: version, **data_by_key)
  end

  # B2: item/variation/category mapping writes SpreePos::ExternalRef, which
  # is connection-scoped (pos_connection_id is NOT NULL), so a resolvable
  # catalog-source connection is now a precondition for every map_* call --
  # not just the tax/modifier ones that needed one since Phase 3. The
  # legacy SpreeSquare::CatalogMapping/TaxonMapping tables this replaced
  # had no connection column at all, which is why these specs never needed
  # one before.
  let!(:pos_connection) do
    SpreePos::Connection.create!(store: store, provider: 'square',
                                  external_merchant_id: 'sq_merchant_1', catalog_role: 'source')
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

    # Was 'records a CatalogMapping for the item'. B2 moved the catalog
    # write path onto SpreePos::ExternalRef; the assertion tracks the move.
    it 'records a SpreePos::ExternalRef for the item, scoped to the connection' do
      product = mapper.map_item(item)
      ref = SpreePos::ExternalRef.find_by(external_id: 'sq_item_1')

      expect(ref.resource_type).to eq(SpreePos::ExternalRef::RESOURCE_ITEM)
      expect(ref.pos_connection).to eq(pos_connection)
      expect(ref.spree_type).to eq('Spree::Product')
      expect(ref.product).to eq(product)
    end

    # Dual-write was explicitly rejected for B2: the legacy tables are kept
    # (they still hold pre-cutover production rows for the reconciliation
    # tooling to read) but nothing writes to them any more. If this ever
    # starts failing, the cutover has silently regressed into a dual-write.
    it 'writes NOTHING to the legacy SpreeSquare::CatalogMapping table' do
      expect { mapper.map_item(item) }.not_to change(SpreeSquare::CatalogMapping, :count).from(0)
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
        item_variation_data: { name: name, pricing_type: 'FIXED_PRICING', price_money: { amount: amount, currency: 'USD' } }
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
