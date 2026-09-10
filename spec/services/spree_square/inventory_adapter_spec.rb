require 'json'

# Characterization spec, written in Phase 0 as SpreeSquare::InventorySync's
# spec, before the class moved anywhere. Phase 2 split InventorySync into
# provider-neutral SpreePos::InventorySync (StockItem write, see its own
# spec) and this class, SpreeSquare::InventoryAdapter.
#
# B2 changed the fixtures, never the assertions: the VARIANT half of the
# resolution moved from SpreeSquare::CatalogMapping to a connection-scoped
# SpreePos::ExternalRef, so the setup now has to build the chain the
# production path walks (connection -> SpreePos::Location -> ExternalRef).
# Every expectation below is still exactly the Phase 0 one, which is what
# makes this evidence the behaviour did not change.
#
# The LOCATION half still resolves through SpreeSquare::LocationMapping;
# that table has its own migration story and is out of B2's scope.
# `catalog_object_id`/`location_id`/`quantity`/`state` are the real
# field names Square's BatchRetrieveInventoryCounts returns (see
# spec/fixtures/square/batch_retrieve_inventory_counts.json and that
# directory's README.md for provenance) — used here for the argument names
# and shapes, since InventoryAdapter.call takes exactly these keywords.
RSpec.describe SpreeSquare::InventoryAdapter do
  let(:fixture) do
    JSON.parse(File.read(File.join(__dir__, '..', '..', 'fixtures', 'square', 'batch_retrieve_inventory_counts.json')))['counts'].first
  end

  let(:store) { Spree::Store.default }
  let(:stock_location) { create(:stock_location, store: store) }
  let(:variant) { create(:variant) }

  # The connection the counts are attributed to. `described_class.call`
  # (used throughout below) passes no connection, exactly as the inventory
  # webhook path does today, so the adapter has to derive it from the
  # count's own location -- which is what this SpreePos::Location makes
  # possible.
  let!(:pos_connection) do
    SpreePos::Connection.create!(store: store, provider: 'square',
                                  external_merchant_id: 'sq_merchant_1', catalog_role: 'source')
  end
  let!(:pos_location) do
    SpreePos::Location.create!(pos_connection: pos_connection, stock_location: stock_location,
                                external_location_id: fixture['location_id'])
  end

  def external_ref(resource_type:, spree_type:, spree_id:)
    SpreePos::ExternalRef.create!(
      pos_connection: pos_connection,
      resource_type: resource_type,
      external_id: fixture['catalog_object_id'],
      spree_type: spree_type,
      spree_id: spree_id
    )
  end

  def call(overrides = {})
    described_class.call(
      catalog_object_id: fixture['catalog_object_id'],
      location_id: fixture['location_id'],
      quantity: fixture['quantity'],
      state: fixture['state'],
      **overrides
    )
  end

  context 'with both mappings present' do
    let!(:variation_ref) do
      external_ref(resource_type: SpreePos::ExternalRef::RESOURCE_VARIATION,
                   spree_type: 'Spree::Variant', spree_id: variant.id)
    end
    let!(:location_mapping) do
      SpreeSquare::LocationMapping.create!(stock_location: stock_location, square_location_id: fixture['location_id'])
    end

    it 'writes the count onto the mapped location\'s stock item for the mapped variant' do
      call

      stock_item = stock_location.stock_items.find_by(variant: variant)
      expect(stock_item.count_on_hand).to eq(fixture['quantity'].to_i)
    end

    it 'never backorders food, regardless of the stock item\'s prior setting' do
      stock_item = stock_location.stock_item_or_create(variant)
      stock_item.update!(backorderable: true)

      call

      expect(stock_item.reload.backorderable).to be false
    end

    it 'zeroes the count for any state other than IN_STOCK' do
      call(state: 'SOLD')

      stock_item = stock_location.stock_items.find_by(variant: variant)
      expect(stock_item.count_on_hand).to eq(0)
    end

    it 'defaults to IN_STOCK when no state is given, matching a webhook payload with no state key' do
      described_class.call(catalog_object_id: fixture['catalog_object_id'], location_id: fixture['location_id'], quantity: '3')

      stock_item = stock_location.stock_items.find_by(variant: variant)
      expect(stock_item.count_on_hand).to eq(3)
    end
  end

  context 'missing the external ref (unmapped Square item)' do
    let!(:location_mapping) do
      SpreeSquare::LocationMapping.create!(stock_location: stock_location, square_location_id: fixture['location_id'])
    end

    it 'is a silent no-op — nothing to write a count against' do
      expect { call }.not_to raise_error
      expect(Spree::StockItem.count).to eq(0)
    end
  end

  context 'missing the location mapping (unmapped Square location)' do
    let!(:variation_ref) do
      external_ref(resource_type: SpreePos::ExternalRef::RESOURCE_VARIATION,
                   spree_type: 'Spree::Variant', spree_id: variant.id)
    end

    it 'is a silent no-op — there is no Spree::StockLocation to write to' do
      # The :variant factory already creates a stock item at whichever
      # default stock location exists (Spree propagates every variant to
      # every location) — the characterization here is "no *new* write", not
      # "zero stock items ever exist".
      before_count = Spree::StockItem.count

      expect { call }.not_to raise_error
      expect(Spree::StockItem.count).to eq(before_count)
    end
  end

  context 'the external ref points at a product (not a variation)' do
    let!(:item_ref) do
      external_ref(resource_type: SpreePos::ExternalRef::RESOURCE_ITEM,
                   spree_type: 'Spree::Product', spree_id: create(:product).id)
    end
    let!(:location_mapping) do
      SpreeSquare::LocationMapping.create!(stock_location: stock_location, square_location_id: fixture['location_id'])
    end

    it 'only ever matches a variation ref' do
      before_count = Spree::StockItem.count

      expect { call }.not_to raise_error
      expect(Spree::StockItem.count).to eq(before_count)
    end
  end
end
