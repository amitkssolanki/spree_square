require 'json'

# Characterization spec, written in Phase 0 before InventorySync moves
# anywhere. `catalog_object_id`/`location_id`/`quantity`/`state` are the real
# field names Square's BatchRetrieveInventoryCounts returns (see
# spec/fixtures/square/batch_retrieve_inventory_counts.json and that
# directory's README.md for provenance) — used here for the argument names
# and shapes, since InventorySync.call takes exactly these keywords.
RSpec.describe SpreeSquare::InventorySync do
  let(:fixture) do
    JSON.parse(File.read(File.join(__dir__, '..', '..', 'fixtures', 'square', 'batch_retrieve_inventory_counts.json')))['counts'].first
  end

  let(:stock_location) { create(:stock_location) }
  let(:variant) { create(:variant) }

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
    let!(:catalog_mapping) do
      SpreeSquare::CatalogMapping.create!(
        square_catalog_object_id: fixture['catalog_object_id'],
        square_object_type: SpreeSquare::CatalogMapping::ITEM_VARIATION,
        variant: variant
      )
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

  context 'missing the catalog mapping (unmapped Square item)' do
    let!(:location_mapping) do
      SpreeSquare::LocationMapping.create!(stock_location: stock_location, square_location_id: fixture['location_id'])
    end

    it 'is a silent no-op — nothing to write a count against' do
      expect { call }.not_to raise_error
      expect(Spree::StockItem.count).to eq(0)
    end
  end

  context 'missing the location mapping (unmapped Square location)' do
    let!(:catalog_mapping) do
      SpreeSquare::CatalogMapping.create!(
        square_catalog_object_id: fixture['catalog_object_id'],
        square_object_type: SpreeSquare::CatalogMapping::ITEM_VARIATION,
        variant: variant
      )
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

  context 'the catalog mapping points at a product (not a variation)' do
    let!(:catalog_mapping) do
      SpreeSquare::CatalogMapping.create!(
        square_catalog_object_id: fixture['catalog_object_id'],
        square_object_type: SpreeSquare::CatalogMapping::ITEM,
        product: create(:product)
      )
    end
    let!(:location_mapping) do
      SpreeSquare::LocationMapping.create!(stock_location: stock_location, square_location_id: fixture['location_id'])
    end

    it 'only ever matches an ITEM_VARIATION mapping' do
      before_count = Spree::StockItem.count

      expect { call }.not_to raise_error
      expect(Spree::StockItem.count).to eq(before_count)
    end
  end
end
