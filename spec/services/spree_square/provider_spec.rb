RSpec.describe SpreeSquare::Provider do
  let(:store) { Spree::Store.default.presence || create(:store) }
  let(:connection) { create(:pos_connection, store: store, provider: 'square') }

  # `locations.list` and `catalog.fetch_all` are exercised for real by the
  # shared example group, so the Square SDK layer underneath them has to be
  # stubbed — the same client-double pattern catalog_importer_spec uses.
  let(:client) { instance_double(SpreeSquare::Client) }
  let(:catalog_api) { double('catalog api') }
  let(:locations_api) { double('locations api') }
  let(:search_response) { double('search response', objects: [], related_objects: [], cursor: nil) }

  before do
    allow(SpreeSquare::Client).to receive(:instance).and_return(client)
    allow(client).to receive(:catalog).and_return(catalog_api)
    allow(client).to receive(:locations).and_return(locations_api)
    allow(catalog_api).to receive(:search).and_return(search_response)
    allow(locations_api).to receive(:list).and_return(double('list response', locations: []))
  end

  # The contract test every provider must pass. This is the guarantee that
  # a second provider cannot half-implement the interface — and, now that
  # Square is a real provider rather than a placeholder, that Square itself
  # actually satisfies it.
  it_behaves_like 'a POS provider'

  describe 'identity' do
    it 'is registered under :square' do
      expect(described_class.key).to eq(:square)
    end

    it 'has a human-facing display name' do
      expect(described_class.display_name).to eq('Square')
    end
  end

  describe 'capabilities' do
    it 'declares :order_idempotency_key, which is what keeps a lost push in `failed` not `ambiguous`' do
      expect(described_class).to be_supports(:order_idempotency_key)
    end

    it 'declares :inventory_pull, which is what makes the inventory paths dispatch here at all' do
      expect(described_class).to be_supports(:inventory_pull)
    end

    it 'does NOT declare per-location catalog capabilities this adapter has never implemented' do
      # Square's API supports both; SpreeSquare::CatalogAdapter ignores
      # `present_at_location_ids` and `location_overrides` entirely (plan
      # Q3/Q7). Declaring them would tell a caller something untrue.
      expect(described_class).not_to be_supports(:catalog_location_availability)
      expect(described_class).not_to be_supports(:catalog_location_pricing)
    end
  end

  describe 'adapter bindings' do
    subject(:provider) { described_class.new(connection) }

    it 'binds auth to the Square OAuth client' do
      expect(provider.auth).to eq(SpreeSquare::OauthClient)
    end

    it 'binds locations to the Square location adapter' do
      expect(provider.locations).to be_a(SpreeSquare::LocationAdapter)
    end

    it 'binds catalog to the Square catalog adapter' do
      expect(provider.catalog).to be_a(SpreeSquare::CatalogAdapter)
    end

    it 'binds orders to the Square order adapter' do
      expect(provider.orders).to be_a(SpreeSquare::OrderAdapter)
    end

    it 'binds webhooks to the Square webhook adapter' do
      expect(provider.webhooks).to eq(SpreeSquare::WebhookAdapter)
    end

    # An INSTANCE since B2, not the class: the adapter needs this
    # provider's connection to scope its SpreePos::ExternalRef lookups.
    it 'binds inventory to the Square inventory adapter, carrying the connection' do
      expect(provider.inventory).to be_a(SpreeSquare::InventoryAdapter)
      expect(provider.inventory.instance_variable_get(:@connection)).to eq(connection)
    end

    it 'binds orders to an adapter carrying the connection, so catalog lookups are tenant-scoped' do
      expect(provider.orders.instance_variable_get(:@connection)).to eq(connection)
    end

    it 'tolerates a nil connection, which the webhook/catalog paths still pass today' do
      expect { described_class.new(nil).webhooks }.not_to raise_error
    end
  end
end
