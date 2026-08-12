RSpec.describe SpreeSquare::OrderPushJob do
  let(:order) { create(:order, state: 'complete', completed_at: Time.current) }

  describe '#perform' do
    it 'pushes the order to Square' do
      expect(SpreeSquare::OrderPusher).to receive(:call).with(order)

      described_class.perform_now(order.id)
    end
  end

  describe 'when retries are exhausted' do
    # This is the one failure mode called out in the job's own comment as
    # the worst in the system (payment taken, kitchen never sees it) — so
    # it gets its own coverage of exactly what happens on the record and
    # what gets alerted, not just that *something* is alerted.
    it 'records the failure on an OrderMapping and alerts with the order number' do
      allow(SpreeSquare::OrderPusher).to receive(:call).and_raise(StandardError, 'square is down')
      expect(SpreeSquare::Alerting).to receive(:capture).with(
        instance_of(StandardError),
        context: { area: 'order_push', order_number: order.number }
      )

      job = described_class.new(order.id)
      job.exception_executions = { '[StandardError]' => 4 }

      expect { job.perform_now }.not_to raise_error

      mapping = SpreeSquare::OrderMapping.find_by(order: order)
      expect(mapping.push_error).to include('square is down')
    end

    it 'still alerts (without a mapping) when the order itself can no longer be found' do
      order_id = order.id
      order.destroy
      expect(SpreeSquare::OrderPusher).not_to receive(:call)

      # retry_on's exhaustion counter is keyed by the *declared* exception
      # list (`StandardError`, what the job's retry_on line names) — not by
      # the concrete class actually raised, which here is
      # ActiveRecord::RecordNotFound bubbling out of Spree::Order.find.
      expect(SpreeSquare::Alerting).to receive(:capture).with(
        instance_of(ActiveRecord::RecordNotFound),
        context: { area: 'order_push', order_number: nil }
      )

      job = described_class.new(order_id)
      job.exception_executions = { '[StandardError]' => 4 }

      expect { job.perform_now }.not_to raise_error
      expect(SpreeSquare::OrderMapping.count).to eq(0)
    end
  end
end
