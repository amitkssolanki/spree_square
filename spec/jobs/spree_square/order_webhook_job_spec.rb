RSpec.describe SpreeSquare::OrderWebhookJob do
  describe '#perform' do
    context 'order.updated' do
      let(:payload) do
        {
          'data' => {
            'object' => {
              'order_updated' => { 'order_id' => 'sq_order_1', 'version' => 3, 'state' => 'COMPLETED' }
            }
          }
        }
      end
      let(:event) do
        SpreeSquare::WebhookEvent.create!(square_event_id: 'evt_1', event_type: 'order.updated', payload: payload)
      end

      it 'maps the order-level state and marks the event processed' do
        expect(SpreeSquare::OrderStatusMapper).to receive(:call).with(
          square_order_id: 'sq_order_1', version: 3, order_state: 'COMPLETED'
        )

        described_class.perform_now(event.id)

        expect(event.reload.status).to eq('processed')
      end
    end

    context 'order.fulfillment.updated' do
      let(:payload) do
        {
          'data' => {
            'object' => {
              'order_fulfillment_updated' => {
                'order_id' => 'sq_order_1',
                'version' => 4,
                'fulfillment_update' => [
                  { 'fulfillment_uid' => 'f1', 'new_state' => 'COMPLETED', 'old_state' => 'PREPARED' }
                ]
              }
            }
          }
        }
      end
      let(:event) do
        SpreeSquare::WebhookEvent.create!(square_event_id: 'evt_2', event_type: 'order.fulfillment.updated', payload: payload)
      end

      it 'maps each fulfillment update and marks the event processed' do
        expect(SpreeSquare::OrderStatusMapper).to receive(:call).with(
          square_order_id: 'sq_order_1', version: 4, fulfillment_state: 'COMPLETED'
        )

        described_class.perform_now(event.id)

        expect(event.reload.status).to eq('processed')
      end

      it 'maps every entry when a single delivery reports multiple fulfillment updates' do
        payload['data']['object']['order_fulfillment_updated']['fulfillment_update'] <<
          { 'fulfillment_uid' => 'f2', 'new_state' => 'CANCELED', 'old_state' => 'RESERVED' }
        event.update!(payload: payload)

        expect(SpreeSquare::OrderStatusMapper).to receive(:call).with(
          square_order_id: 'sq_order_1', version: 4, fulfillment_state: 'COMPLETED'
        )
        expect(SpreeSquare::OrderStatusMapper).to receive(:call).with(
          square_order_id: 'sq_order_1', version: 4, fulfillment_state: 'CANCELED'
        )

        described_class.perform_now(event.id)
      end
    end

    it 'marks an event of an unrecognized type processed without mapping anything' do
      event = SpreeSquare::WebhookEvent.create!(square_event_id: 'evt_3', event_type: 'order.something.else', payload: {})

      expect(SpreeSquare::OrderStatusMapper).not_to receive(:call)

      described_class.perform_now(event.id)

      expect(event.reload.status).to eq('processed')
    end
  end

  describe 'when retries are exhausted' do
    it 'marks the webhook event failed and alerts, and does not let the error escape' do
      event = SpreeSquare::WebhookEvent.create!(
        square_event_id: 'evt_4', event_type: 'order.updated',
        payload: { 'data' => { 'object' => { 'order_updated' => { 'order_id' => 'sq_order_1' } } } }
      )
      allow(SpreeSquare::OrderStatusMapper).to receive(:call).and_raise(StandardError, 'boom')
      expect(SpreeSquare::Alerting).to receive(:capture).with(instance_of(StandardError), context: 'order_webhook')

      job = described_class.new(event.id)
      job.exception_executions = { '[StandardError]' => 4 }

      expect { job.perform_now }.not_to raise_error

      expect(event.reload.status).to eq('failed')
    end
  end
end
