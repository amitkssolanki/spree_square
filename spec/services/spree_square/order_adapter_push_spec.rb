require 'json'

# Characterization spec, written in Phase 0 before OrderPusher moved anywhere
# (Phase 2, sequence step 16a/16b — see the plan). Values below come from the
# real Square response shapes recorded in spec/fixtures/square/create_order.json
# and create_payment.json (see that directory's README.md for provenance).
#
# OrderAdapter#build_payload already has its own 302-line characterization
# spec covering payload construction — this spec isolates the two behaviours
# the plan specifically calls out for the push side: paying exactly Square's
# own total_money (never a locally recomputed total), and the post-payment
# re-read that keeps the returned result's status current.
#
# Phase 2D, step 16b moved the mapping bookkeeping (find-or-create,
# push_state, dedup on a second push) off this class entirely and onto
# SpreePos::OrderPush -- #push now returns a plain SpreePos::Orders::
# PushResult instead of a SpreeSquare::OrderMapping, so those assertions
# moved with it to spec/models/spree_pos/order_push_spec.rb in spree_pos.
# This file keeps only the assertions that are genuinely about what this
# adapter does with the Square API, unchanged from before.
RSpec.describe SpreeSquare::OrderAdapter do
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

  let(:connection) { create(:pos_connection, provider: 'square') }

  subject(:adapter) { described_class.new(connection: connection) }

  before do
    # The adapter's own connection's client (multi-tenancy, 2026-09-13).
    allow(SpreeSquare::Client).to receive(:for_connection).with(connection).and_return(client)
    allow(adapter).to receive(:build_payload).with(order).and_return(builder_payload)
    allow(orders_api).to receive(:create)
      .with(idempotency_key: "spree-order-#{order.number}", order: builder_payload)
      .and_return(double('CreateOrderResponse', order: square_order))
    allow(orders_api).to receive(:get).with(order_id: order_fixture['id']).and_return(double('GetOrderResponse', order: refreshed_square_order))
    allow(payments_api).to receive(:create).and_return(double('CreatePaymentResponse', payment: square_payment))
  end

  it 'charges exactly the total_money Square computed for the order it just created' do
    adapter.push(order)

    expect(payments_api).to have_received(:create).with(
      hash_including(
        amount_money: { amount: order_fixture['total_money']['amount'], currency: order_fixture['total_money']['currency'] },
        source_id: 'EXTERNAL',
        order_id: order_fixture['id']
      )
    )
  end

  it 'never recomputes the total from the local Spree order' do
    # If #push ever starts deriving the charge from order.total instead of
    # square_order.total_money, this is the spec that catches it: assert the
    # two disagree going in, so a regression that quietly switches the
    # source can't pass by coincidentally matching.
    expect((order.total.to_f * 100).to_i).not_to eq(order_fixture['total_money']['amount'])

    adapter.push(order)

    expect(payments_api).to have_received(:create).with(hash_including(amount_money: { amount: 6176, currency: 'USD' }))
  end

  it 'returns a PushResult built from the initial create-order response' do
    result = adapter.push(order)

    expect(result).to be_a(SpreePos::Orders::PushResult)
    expect(result.external_order_id).to eq(order_fixture['id'])
    expect(result.external_location_id).to eq(order_fixture['location_id'])
  end

  it 're-reads the order after payment so the result reflects the post-payment state, not the pre-payment snapshot' do
    result = adapter.push(order)

    expect(result.status).to eq('COMPLETED')
    expect(result.external_version).to eq(order_fixture['version'] + 1)
    expect(result.external_payment_id).to eq(payment_fixture['id'])
  end
end
