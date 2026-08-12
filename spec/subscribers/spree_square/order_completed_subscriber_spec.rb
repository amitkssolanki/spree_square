RSpec.describe SpreeSquare::OrderCompletedSubscriber do
  describe '.call' do
    it 'enqueues an OrderPushJob for the order referenced in the event payload' do
      order = create(:order)
      event = Spree::Event.new(name: 'order.completed', payload: { 'id' => order.to_param })

      expect(SpreeSquare::OrderPushJob).to receive(:perform_later).with(order.id)

      described_class.call(event)
    end

    it 'is a safe no-op when the payload id does not resolve to a real order' do
      event = Spree::Event.new(name: 'order.completed', payload: { 'id' => 'or_doesnotexist' })

      expect(SpreeSquare::OrderPushJob).not_to receive(:perform_later)

      expect { described_class.call(event) }.not_to raise_error
    end
  end
end
