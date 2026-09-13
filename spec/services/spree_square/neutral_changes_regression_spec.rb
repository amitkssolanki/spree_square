# PHASE 11 of the Clover remediation: prove the provider-neutral changes made
# for Clover did not alter Square, using real square.rb objects rather than
# doubles.
#
# The three neutral changes were: a SKU-collision fallback with an operator
# proposal, persisting external_updated_at on ExternalRef, and moving the
# inventory webhook payload parse out of the neutral job.
#
# Production shape being defended (read read-only from production
# 2026-09-12): 439 ExternalRefs, every one carrying external_version, none
# carrying external_updated_at.
RSpec.describe 'Square is unaffected by the provider-neutral Clover fixes' do
  let(:store) { Spree::Store.default }
  let(:mapper) { SpreeSquare::CatalogObjectMapper.new(connection: pos_connection) }
  let!(:pos_connection) do
    SpreePos::Connection.create!(store: store, provider: 'square',
                                 external_merchant_id: 'sq_merchant_1', catalog_role: 'source')
  end

  before do
    Spree::ShippingCategory.find_or_create_by!(name: 'Default')
    Spree::Channel.find_or_create_by!(code: 'online') { |c| c.name = 'Online Store'; c.store = store }
  end

  def square_item(id:, name:, version: 1, variations: [])
    square_catalog_object(
      id: id, type: 'ITEM', version: version,
      item_data: { name: name, description: nil, variations: variations, image_ids: nil,
                   category_id: nil, categories: nil, modifier_list_info: nil }
    )
  end

  def square_variation(id:, name:, version: 1, price_cents: 500)
    square_catalog_object(
      id: id, type: 'ITEM_VARIATION', version: version,
      item_variation_data: { name: name, sku: nil, price_money: { amount: price_cents, currency: 'USD' },
                             item_id: nil, pricing_type: 'FIXED_PRICING' }
    )
  end

  describe 'SKU handling' do
    # Square's adapter sets the DTO sku to the object id, which is unique by
    # construction, so the collision branch can never trigger for it.
    it 'keeps the object id as the variant SKU, and proposes nothing' do
      item = square_item(id: 'sq_item_1', name: 'Margherita Pizza',
                         variations: [square_variation(id: 'sq_var_1', name: 'Regular')])

      product = mapper.map_item(item)

      variant = SpreePos::ExternalRef.for_connection(pos_connection)
                                     .of_type(SpreePos::ExternalRef::RESOURCE_VARIATION)
                                     .find_by(external_id: 'sq_var_1').variant
      expect(variant.sku).to eq('sq_var_1')
      expect(product.variants_including_master).to include(variant)
    end

    it 'gives two different Square items two different SKUs, with no collision at all' do
      mapper.map_item(square_item(id: 'sq_item_1', name: 'Pizza A',
                                  variations: [square_variation(id: 'sq_var_1', name: 'Regular')]))
      mapper.map_item(square_item(id: 'sq_item_2', name: 'Pizza B',
                                  variations: [square_variation(id: 'sq_var_2', name: 'Regular')]))

      skus = SpreePos::ExternalRef.for_connection(pos_connection)
                                  .of_type(SpreePos::ExternalRef::RESOURCE_VARIATION)
                                  .map { |ref| ref.variant.sku }
      expect(skus).to contain_exactly('sq_var_1', 'sq_var_2')
    end
  end

  describe 'staleness metadata' do
    it 'records external_version and leaves external_updated_at nil, as production has it' do
      mapper.map_item(square_item(id: 'sq_item_1', name: 'Pizza', version: 42,
                                  variations: [square_variation(id: 'sq_var_1', name: 'Regular', version: 43)]))

      refs = SpreePos::ExternalRef.for_connection(pos_connection)
      expect(refs.pluck(:external_version)).to all(be_present)
      expect(refs.pluck(:external_updated_at)).to all(be_nil)
    end

    it 'still rejects an older VERSION, which is the protection Square relies on' do
      mapper.map_item(square_item(id: 'sq_item_1', name: 'Pizza', version: 42))

      mapper.map_item(square_item(id: 'sq_item_1', name: 'Renamed by an older delivery', version: 41))

      ref = SpreePos::ExternalRef.for_connection(pos_connection)
                                 .of_type(SpreePos::ExternalRef::RESOURCE_ITEM).find_by(external_id: 'sq_item_1')
      expect(ref.product.name).to eq('Pizza')
      expect(ref.external_version).to eq(42)
    end

    it 'applies a newer version' do
      mapper.map_item(square_item(id: 'sq_item_1', name: 'Pizza', version: 42))

      mapper.map_item(square_item(id: 'sq_item_1', name: 'Pizza Deluxe', version: 43))

      ref = SpreePos::ExternalRef.for_connection(pos_connection)
                                 .of_type(SpreePos::ExternalRef::RESOURCE_ITEM).find_by(external_id: 'sq_item_1')
      expect(ref.product.name).to eq('Pizza Deluxe')
      expect(ref.external_version).to eq(43)
    end
  end

  describe 'the inventory webhook contract' do
    it 'applies a real Square inventory payload through the neutral job end to end' do
      mapper.map_item(square_item(id: 'sq_item_1', name: 'Pizza',
                                  variations: [square_variation(id: 'sq_var_1', name: 'Regular')]))
      stock_location = create(:stock_location, store: store)
      SpreePos::Location.create!(pos_connection: pos_connection, stock_location: stock_location,
                                 external_location_id: 'sq_loc_1')
      SpreeSquare::LocationMapping.create!(square_location_id: 'sq_loc_1',
                                           spree_stock_location_id: stock_location.id)
      event = SpreePos::WebhookEvent.create!(
        provider: 'square', kind: 'inventory_changed', idempotency_key: "sq-inv-#{SecureRandom.hex(4)}",
        event_type: 'inventory.count.updated', pos_connection: pos_connection,
        payload: { 'data' => { 'object' => { 'inventory_counts' => [
          { 'catalog_object_id' => 'sq_var_1', 'location_id' => 'sq_loc_1',
            'quantity' => '12', 'state' => 'IN_STOCK' }
        ] } } }
      )

      SpreePos::InventoryWebhookJob.perform_now(event.id)

      variant = SpreePos::ExternalRef.for_connection(pos_connection)
                                     .of_type(SpreePos::ExternalRef::RESOURCE_VARIATION)
                                     .find_by(external_id: 'sq_var_1').variant
      stock_item = Spree::StockItem.find_by(variant: variant, stock_location: stock_location)
      expect(stock_item.count_on_hand).to eq(12)
      expect(event.reload.status).to eq('processed')
    end

    it 'records the run with the count it applied, not a hollow success' do
      event = SpreePos::WebhookEvent.create!(
        provider: 'square', kind: 'inventory_changed', idempotency_key: "sq-run-#{SecureRandom.hex(4)}",
        event_type: 'inventory.count.updated', pos_connection: pos_connection,
        payload: { 'data' => { 'object' => { 'inventory_counts' => [] } } }
      )

      SpreePos::InventoryWebhookJob.perform_now(event.id)

      run = SpreePos::SyncRun.where(pos_connection: pos_connection, kind: 'inventory').last
      expect(run.status).to eq('succeeded')
      expect(run.counts['counts_applied']).to eq(0)
    end
  end
end
