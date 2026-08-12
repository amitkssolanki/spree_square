RSpec.describe SpreeSquare::ReconciliationJob do
  describe '#perform' do
    it 'runs a full catalog import' do
      expect(SpreeSquare::CatalogImporter).to receive(:call)
      allow(SpreeSquare::LocationMapping).to receive(:pluck).and_return([])

      described_class.perform_now
    end

    context 'with no location mappings' do
      it 'fetches no inventory counts (returns before calling the Square client at all)' do
        allow(SpreeSquare::CatalogImporter).to receive(:call)
        client = instance_double(SpreeSquare::Client)
        allow(SpreeSquare::Client).to receive(:instance).and_return(client)
        expect(client).not_to receive(:inventory)

        described_class.perform_now
      end
    end

    context 'with a mapped location' do
      let(:stock_location) { create(:stock_location) }
      let!(:location_mapping) do
        SpreeSquare::LocationMapping.create!(spree_stock_location_id: stock_location.id, square_location_id: 'sq_loc_1')
      end
      let(:count) { double('InventoryCount', catalog_object_id: 'sq_var_1', location_id: 'sq_loc_1', quantity: '2', state: 'IN_STOCK') }
      let(:client) { instance_double(SpreeSquare::Client) }
      let(:inventory) { double('inventory') }

      before do
        allow(SpreeSquare::CatalogImporter).to receive(:call)
        allow(SpreeSquare::Client).to receive(:instance).and_return(client)
        allow(client).to receive(:inventory).and_return(inventory)
        allow(inventory).to receive(:batch_get_counts).with(location_ids: ['sq_loc_1']).and_return([count])
      end

      it 'reconciles inventory for every mapped Square location, with no states filter' do
        expect(SpreeSquare::InventorySync).to receive(:call).with(
          catalog_object_id: 'sq_var_1', location_id: 'sq_loc_1', quantity: '2', state: 'IN_STOCK'
        )

        described_class.perform_now
      end
    end
  end

  describe 'when retries are exhausted' do
    # attempts: 3 here (not 5 like the other jobs) — one below that limit is 2.
    it 'alerts (there is no webhook_event/order_mapping for a job with no id argument)' do
      allow(SpreeSquare::CatalogImporter).to receive(:call).and_raise(StandardError, 'boom')
      expect(SpreeSquare::Alerting).to receive(:capture).with(instance_of(StandardError), context: 'reconciliation')

      job = described_class.new
      job.exception_executions = { '[StandardError]' => 2 }

      expect { job.perform_now }.not_to raise_error
    end
  end
end
