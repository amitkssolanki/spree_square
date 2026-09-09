require 'json'

# Characterization spec, written in Phase 0 before OrderPusher moves anywhere
# (Phase 2, sequence step 16a/16b — see the plan). Values below come from the
# real Square response shapes recorded in spec/fixtures/square/create_order.json
# and create_payment.json (see that directory's README.md for provenance).
#
# OrderBuilder already has its own 302-line characterization spec covering
# payload construction — this spec isolates the two behaviours the plan
# specifically calls out for OrderPusher: paying exactly Square's own
# total_money (never a locally recomputed total), and the post-payment
# re-read that keeps the mapping's status current.
RSpec.describe SpreeSquare::OrderPusher do
  around do |example|
    Spree::LineItem.skip_callback(:save, :after, :update_inventory)
    example.run
    Spree::LineItem.set_callback(:save, :after, :update_inventory)
  end

  let(:order_fixture) { JSON.parse(File.read(File.join(__dir__, '..', '..', 'fixtures', 'square', 'create_order.json')))['order'] }
  let(:payment_fixture) { JSON.parse(File.read(File.join(__dir__, '..', '..', 'fixtures', 'square', 'create_payment.json')))['payment'] }

  let(:order) { create(:order, state: 'complete', completed_at: Time.current) }
  let(:builder_payload) { { reference_id: order.number } }

  let(:square_order) do
    double('Square::Types::Order',
           id: order_fixture['id'],
           location_id: order_fixture['location_id'],
           version: order_fixture['version'],
           state: order_fixture['state'],
           total_money: double('Money', amount: order_fixture['total_money']['amount'], currency: order_fixture['total_money']['currency']))
  end
  # The refreshed order returned by the post-payment `orders.get` re-read —
  # same order, but Square has advanced it (paying it off can move it
  # straight to COMPLETED).
  let(:refreshed_square_order) do
    double('Square::Types::Order', id: order_fixture['id'], version: order_fixture['version'] + 1, state: 'COMPLETED')
  end
  let(:square_payment) { double('Square::Types::Payment', id: payment_fixture['id']) }

  let(:orders_api) { double('orders_api') }
  let(:payments_api) { double('payments_api') }
  let(:client) { instance_double(SpreeSquare::Client, orders: orders_api, payments: payments_api) }

  before do
    allow(SpreeSquare::Client).to receive(:instance).and_return(client)
    allow(SpreeSquare::OrderBuilder).to receive(:call).with(order).and_return(builder_payload)
    allow(orders_api).to receive(:create)
      .with(idempotency_key: "spree-order-#{order.number}", order: builder_payload)
      .and_return(double('CreateOrderResponse', order: square_order))
    allow(orders_api).to receive(:get).with(order_id: order_fixture['id']).and_return(double('GetOrderResponse', order: refreshed_square_order))
    allow(payments_api).to receive(:create).and_return(double('CreatePaymentResponse', payment: square_payment))
  end

  it 'charges exactly the total_money Square computed for the order it just created' do
    described_class.call(order)

    expect(payments_api).to have_received(:create).with(
      hash_including(
        amount_money: { amount: order_fixture['total_money']['amount'], currency: order_fixture['total_money']['currency'] },
        source_id: 'EXTERNAL',
        order_id: order_fixture['id']
      )
    )
  end

  it 'never recomputes the total from the local Spree order' do
    # If OrderPusher ever starts deriving the charge from order.total instead
    # of square_order.total_money, this is the spec that catches it: assert
    # the two disagree going in, so a regression that quietly switches the
    # source can't pass by coincidentally matching.
    expect((order.total.to_f * 100).to_i).not_to eq(order_fixture['total_money']['amount'])

    described_class.call(order)

    expect(payments_api).to have_received(:create).with(hash_including(amount_money: { amount: 6176, currency: 'USD' }))
  end

  it 'records the mapping from the initial create-order response first' do
    mapping = described_class.call(order)

    expect(mapping).to be_a(SpreeSquare::OrderMapping)
    expect(mapping.square_order_id).to eq(order_fixture['id'])
    expect(mapping.square_location_id).to eq(order_fixture['location_id'])
  end

  it 're-reads the order after payment so the mapping reflects the post-payment state, not the pre-payment snapshot' do
    mapping = described_class.call(order)

    expect(mapping.last_status).to eq('COMPLETED')
    expect(mapping.square_version).to eq(order_fixture['version'] + 1)
    expect(mapping.square_payment_id).to eq(payment_fixture['id'])
  end

  it 'finds or initializes a single mapping per order rather than creating duplicates on a second push' do
    first = described_class.call(order)
    second = described_class.call(order)

    expect(second.id).to eq(first.id)
    expect(SpreeSquare::OrderMapping.where(order: order).count).to eq(1)
  end
end
