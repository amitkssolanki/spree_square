RSpec.describe SpreeSquare::CatalogWebhookJob do
  let(:event) do
    SpreeSquare::WebhookEvent.create!(square_event_id: 'evt_1', event_type: 'catalog.version.updated', payload: {})
  end

  describe '#perform' do
    it 'runs a full catalog import and marks the webhook event processed' do
      expect(SpreeSquare::CatalogImporter).to receive(:call)

      described_class.perform_now(event.id)

      expect(event.reload.status).to eq('processed')
      expect(event.processed_at).to be_present
    end
  end

  describe 'when retries are exhausted' do
    # retry_on's block only runs once the configured attempts (5, here) are
    # used up. Rather than actually retrying 5 times through real backoff
    # delays, set the job's own per-exception counter to one below the
    # limit so the next raise is treated as the final attempt — this is the
    # same counter (`exception_executions`, keyed by the exception list)
    # that ActiveJob's retry_on itself increments and checks.
    it 'marks the webhook event failed and alerts, and does not let the error escape' do
      allow(SpreeSquare::CatalogImporter).to receive(:call).and_raise(StandardError, 'boom')
      expect(SpreeSquare::Alerting).to receive(:capture).with(instance_of(StandardError), context: 'catalog_webhook')

      job = described_class.new(event.id)
      job.exception_executions = { '[StandardError]' => 4 }

      expect { job.perform_now }.not_to raise_error

      expect(event.reload.status).to eq('failed')
      expect(event.error_message).to include('boom')
    end

    it 'is a safe no-op if the webhook event was somehow already removed' do
      allow(SpreeSquare::CatalogImporter).to receive(:call).and_raise(StandardError, 'boom')
      expect(SpreeSquare::Alerting).to receive(:capture)

      job = described_class.new(-1)
      job.exception_executions = { '[StandardError]' => 4 }

      expect { job.perform_now }.not_to raise_error
    end
  end
end
