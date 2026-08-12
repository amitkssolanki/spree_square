RSpec.describe SpreeSquare::OrderStatusMapper do
  let(:order) { create(:order, state: 'complete', completed_at: Time.current) }
  let!(:shipment) { create(:shipment, order: order, state: 'ready') }
  let!(:mapping) { SpreeSquare::OrderMapping.create!(order: order, square_order_id: 'sq_order_1') }

  def call(**args)
    described_class.call(square_order_id: 'sq_order_1', version: 1, **args)
  end

  describe 'fulfillment state COMPLETED' do
    it 'ships the ready shipment' do
      call(fulfillment_state: 'COMPLETED')

      expect(shipment.reload.state).to eq('shipped')
    end

    it 'is idempotent when called twice' do
      call(fulfillment_state: 'COMPLETED')
      expect { call(fulfillment_state: 'COMPLETED') }.not_to raise_error
      expect(shipment.reload.state).to eq('shipped')
    end
  end

  describe 'fulfillment state CANCELED (the real cancel signal for a paid order)' do
    it 'cancels the Spree order' do
      call(fulfillment_state: 'CANCELED')

      expect(order.reload.state).to eq('canceled')
    end

    it 'does not touch the shipment directly (Order#after_cancel handles that)' do
      call(fulfillment_state: 'CANCELED')

      # Spree's own after_cancel callback cancels shipments; we don't call
      # ship!/cancel! on the shipment ourselves for this path.
      expect(order.reload.canceled?).to be true
    end
  end

  describe 'fulfillment state FAILED' do
    it 'also cancels the order' do
      call(fulfillment_state: 'FAILED')

      expect(order.reload.state).to eq('canceled')
    end
  end

  describe 'fulfillment states with no Spree-side action (PROPOSED/RESERVED/PREPARED)' do
    %w[PROPOSED RESERVED PREPARED].each do |state|
      it "does not ship or cancel the order for #{state}" do
        call(fulfillment_state: state)

        expect(shipment.reload.state).to eq('ready')
        expect(order.reload.state).to eq('complete')
      end

      it "still records last_status as #{state}" do
        call(fulfillment_state: state)

        expect(mapping.reload.last_status).to eq(state)
      end
    end
  end

  describe 'order-level state CANCELED (order canceled before any payment attached)' do
    it 'cancels the Spree order' do
      call(order_state: 'CANCELED')

      expect(order.reload.state).to eq('canceled')
    end
  end

  describe 'order-level state COMPLETED' do
    it 'ships the ready shipment' do
      call(order_state: 'COMPLETED')

      expect(shipment.reload.state).to eq('shipped')
    end
  end

  describe 'events for the same mutation sharing one version number' do
    # Regression test for the real bug found in M6: order.updated and
    # order.fulfillment.updated can report the identical version for the
    # same underlying change. A version-based staleness gate would let
    # whichever job ran first "claim" that version and silently drop the
    # other's information. This must not gate at all — both must apply.
    it 'applies fulfillment CANCELED even after an order.updated event reported the same version' do
      call(order_state: 'OPEN', version: 5)
      call(fulfillment_state: 'CANCELED', version: 5)

      expect(order.reload.state).to eq('canceled')
    end

    it 'applies fulfillment CANCELED even when it arrives before the order.updated event of the same version' do
      call(fulfillment_state: 'CANCELED', version: 5)
      call(order_state: 'OPEN', version: 5)

      expect(order.reload.state).to eq('canceled')
    end
  end

  describe 'an unmapped square_order_id' do
    it 'is a safe no-op' do
      expect do
        described_class.call(square_order_id: 'sq_does_not_exist', version: 1, fulfillment_state: 'COMPLETED')
      end.not_to raise_error
    end
  end

  describe 'refunds' do
    it 'never triggers a refund on cancellation — only Spree-side bookkeeping changes' do
      expect(SpreeSquare::Client).not_to receive(:instance)

      call(fulfillment_state: 'CANCELED')
    end
  end
end
