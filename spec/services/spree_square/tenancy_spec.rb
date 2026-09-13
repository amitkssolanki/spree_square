# Two stores, each with its own Square credential, connection and location.
# Every Square call made for a connection must use THAT connection's store
# credential. Before 2026-09-13 the catalog, location, order and inventory
# adapters all resolved `SpreeSquare::Client.instance`, the DEFAULT store's
# credential, so store B's orders were created in store A's Square merchant.
RSpec.describe 'Square tenant isolation' do
  let(:store_a) { Spree::Store.default.presence || create(:store) }
  let(:store_b) { create(:store, code: 'brand-b') }
  let!(:credential_a) { create(:square_credential, store: store_a, square_merchant_id: 'MERCH_A', access_token: 'token-a', expires_at: 20.days.from_now) }
  let!(:credential_b) { create(:square_credential, store: store_b, square_merchant_id: 'MERCH_B', access_token: 'token-b', expires_at: 20.days.from_now) }
  let(:connection_a) { create(:pos_connection, store: store_a, provider: 'square', external_merchant_id: 'MERCH_A') }
  let(:connection_b) { create(:pos_connection, store: store_b, provider: 'square', external_merchant_id: 'MERCH_B') }
  let(:tokens) { [] }

  around do |example|
    original = ENV.to_h.slice('SQUARE_ACCESS_TOKEN', 'SQUARE_ENVIRONMENT')
    ENV.delete('SQUARE_ACCESS_TOKEN')
    ENV['SQUARE_ENVIRONMENT'] = 'sandbox'
    example.run
    %w[SQUARE_ACCESS_TOKEN SQUARE_ENVIRONMENT].each { |k| original[k] ? ENV[k] = original[k] : ENV.delete(k) }
  end

  def capture_square_tokens(api = {})
    allow(Square::Client).to receive(:new) do |**kwargs|
      tokens << kwargs[:token]
      double('Square::Client', **api)
    end
  end

  describe SpreeSquare::Client, '.for_connection' do
    it "uses each connection's own store credential" do
      capture_square_tokens

      SpreeSquare::Client.for_connection(connection_a)
      SpreeSquare::Client.for_connection(connection_b)

      expect(tokens).to eq(%w[token-a token-b])
    end

    it "refuses a credential that belongs to a different merchant than the connection's" do
      credential_b.update!(square_merchant_id: 'MERCH_B_RECONNECTED')

      expect { SpreeSquare::Client.for_connection(connection_b) }
        .to raise_error(SpreeSquare::Client::CredentialMismatchError, /different merchant/)
    end

    it 'refuses to build a client without a connection' do
      expect { SpreeSquare::Client.for_connection(nil) }.to raise_error(SpreeSquare::Client::CredentialMismatchError)
    end
  end

  describe 'the provider adapters' do
    before { allow(SpreeSquare::Client).to receive(:instance).and_raise('default-store client used by a provider') }

    it "reads store B's locations and catalog with store B's token only" do
      locations_api = double('locations', list: double(locations: []))
      catalog_api = double('catalog', search: double(objects: [], related_objects: [], cursor: nil))
      capture_square_tokens(locations: locations_api, catalog: catalog_api)

      provider = SpreeSquare::Provider.new(connection_b)
      provider.locations.list
      provider.catalog.fetch_all

      expect(tokens).to eq(%w[token-b token-b])
    end

    it "imports store B's catalog into store B, never into the default store" do
      catalog_api = double('catalog', search: double(objects: [], related_objects: [], cursor: nil))
      capture_square_tokens(catalog: catalog_api)
      expect(SpreePos::CatalogSync).to receive(:new).with(connection: connection_b).and_call_original

      SpreeSquare::Provider.new(connection_b).catalog.import!

      expect(tokens).to eq(%w[token-b])
    end
  end

  describe 'order push' do
    let(:stock_location_b) { create(:stock_location, store: store_b) }
    let!(:pos_location_b) do
      create(:pos_location, :order_push_enabled, pos_connection: connection_b, stock_location: stock_location_b,
                                                 external_location_id: 'SQLOC_B')
    end
    let!(:mapping_b) { SpreeSquare::LocationMapping.create!(stock_location: stock_location_b, square_location_id: 'SQLOC_B') }
    let(:order_b) { create(:order, store: store_b) }

    it "creates store B's order with store B's credential" do
      orders_api = double('orders')
      capture_square_tokens(orders: orders_api, payments: double('payments'))
      adapter = SpreeSquare::OrderAdapter.new(connection: connection_b)
      allow(adapter).to receive(:create_order).and_raise(SpreePos::PermanentError, 'stop before any Square write')

      expect { adapter.push(order_b) }.to raise_error(SpreePos::PermanentError, 'stop before any Square write')
      expect(tokens).to eq(%w[token-b])
    end

    it "refuses to build a payload for a location that belongs to another connection" do
      allow(order_b).to receive(:fulfilling_stock_location).and_return(stock_location_b)

      expect { SpreeSquare::OrderAdapter.new(connection: connection_a).build_payload(order_b) }
        .to raise_error(SpreePos::PermanentError, /does not belong to connection #{connection_a.id}/)
    end
  end

  describe 'inventory' do
    let(:stock_location_a) { create(:stock_location, store: store_a) }
    let(:stock_location_b) { create(:stock_location, store: store_b) }
    let!(:pos_location_a) { create(:pos_location, pos_connection: connection_a, stock_location: stock_location_a, external_location_id: 'SQLOC_A') }
    let!(:pos_location_b) { create(:pos_location, pos_connection: connection_b, stock_location: stock_location_b, external_location_id: 'SQLOC_B') }
    let!(:legacy_a) { SpreeSquare::LocationMapping.create!(stock_location: stock_location_a, square_location_id: 'SQLOC_A') }
    let!(:legacy_b) { SpreeSquare::LocationMapping.create!(stock_location: stock_location_b, square_location_id: 'SQLOC_B') }

    it "reconciles only the connection's own Square locations, with its own token" do
      inventory_api = double('inventory')
      capture_square_tokens(inventory: inventory_api)
      expect(inventory_api).to receive(:batch_get_counts).with(location_ids: ['SQLOC_B']).and_return([])

      SpreeSquare::InventoryAdapter.new(connection: connection_b).reconcile_all!

      expect(tokens).to eq(%w[token-b])
    end

    it "never writes store A's stock for a count naming store A's location on store B's connection" do
      product_a = create(:product, store: store_a)
      SpreePos::ExternalRef.create!(pos_connection: connection_b, resource_type: 'variation', external_id: 'VAR1',
                                    spree_type: 'Spree::Variant', spree_id: product_a.master.id)
      expect(SpreePos::InventorySync).not_to receive(:call)

      SpreeSquare::InventoryAdapter.new(connection: connection_b).call(catalog_object_id: 'VAR1', location_id: 'SQLOC_A',
                                                                     quantity: '99', state: 'IN_STOCK')
    end
  end
end
