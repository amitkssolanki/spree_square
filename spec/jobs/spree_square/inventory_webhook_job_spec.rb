RSpec.describe SpreeSquare::InventoryWebhookJob do
  let(:payload) do
    {
      'data' => {
        'object' => {
          'inventory_counts' => [
            { 'catalog_object_id' => 'sq_var_1', 'location_id' => 'sq_loc_1', 'quantity' => '3', 'state' => 'IN_STOCK' },
            { 'catalog_object_id' => 'sq_var_2', 'location_id' => 'sq_loc_1', 'quantity' => '0', 'state' => 'IN_STOCK' }
          ]
        }
      }
    }
  end
  let(:event) do
    SpreeSquare::WebhookEvent.create!(square_event_id: 'evt_1', event_type: 'inventory.count.updated', payload: payload)
  end

  describe '#perform' do
    it 'syncs every inventory count in the payload and marks the event processed' do
      expect(SpreeSquare::InventorySync).to receive(:call).with(
        catalog_object_id: 'sq_var_1', location_id: 'sq_loc_1', quantity: '3', state: 'IN_STOCK'
      )
      expect(SpreeSquare::InventorySync).to receive(:call).with(
        catalog_object_id: 'sq_var_2', location_id: 'sq_loc_1', quantity: '0', state: 'IN_STOCK'
      )

      described_class.perform_now(event.id)

      expect(event.reload.status).to eq('processed')
    end

    it 'is a no-op (but still marks processed) when the payload has no inventory_counts' do
      empty_event = SpreeSquare::WebhookEvent.create!(square_event_id: 'evt_empty', event_type: 'inventory.count.updated', payload: {})

      expect(SpreeSquare::InventorySync).not_to receive(:call)

      described_class.perform_now(empty_event.id)

      expect(empty_event.reload.status).to eq('processed')
    end
  end

  describe 'when retries are exhausted' do
    it 'marks the webhook event failed and alerts, and does not let the error escape' do
      allow(SpreeSquare::InventorySync).to receive(:call).and_raise(StandardError, 'boom')
      expect(SpreeSquare::Alerting).to receive(:capture).with(instance_of(StandardError), context: 'inventory_webhook')

      job = described_class.new(event.id)
      job.exception_executions = { '[StandardError]' => 4 }

      expect { job.perform_now }.not_to raise_error

      expect(event.reload.status).to eq('failed')
    end
  end
end
