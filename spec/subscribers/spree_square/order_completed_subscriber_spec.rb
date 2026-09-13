RSpec.describe SpreeSquare::OrderCompletedSubscriber do
  describe '.call' do
    it 'enqueues an OrderPushJob for the order referenced in the event payload' do
      order = create(:order)
      event = Spree::Event.new(name: 'order.completed', payload: { 'id' => order.to_param })

      expect(SpreeSquare::OrderPushJob).to receive(:perform_later).with(order.id)

      described_class.call(event)
    end

    it 'does not enqueue for an order at a mapped location whose order pushing is disabled' do
      order = create(:order)
      allow(Spree::Order).to receive(:find_by_prefix_id).and_return(order)
      allow(SpreePos::OrderPushGate).to receive(:refuses?).with(order).and_return(true)
      event = Spree::Event.new(name: 'order.completed', payload: { 'id' => order.to_param })

      expect(SpreeSquare::OrderPushJob).not_to receive(:perform_later)

      described_class.call(event)
    end

    it 'still enqueues when the gate does not refuse, which is every enabled Square location' do
      order = create(:order)
      allow(Spree::Order).to receive(:find_by_prefix_id).and_return(order)
      allow(SpreePos::OrderPushGate).to receive(:refuses?).with(order).and_return(false)

      expect(SpreeSquare::OrderPushJob).to receive(:perform_later).with(order.id)

      described_class.call(Spree::Event.new(name: 'order.completed', payload: { 'id' => order.to_param }))
    end

    it 'is a safe no-op when the payload id does not resolve to a real order' do
      event = Spree::Event.new(name: 'order.completed', payload: { 'id' => 'or_doesnotexist' })

      expect(SpreeSquare::OrderPushJob).not_to receive(:perform_later)

      expect { described_class.call(event) }.not_to raise_error
    end
  end
end
