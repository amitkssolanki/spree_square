# Acceptance test 4/E: order push resolves Square THROUGH THE REGISTRY,
# rather than requiring the caller to inject a concrete Square adapter.
#
# Lives in spree_square's suite because it needs both the provider-neutral
# SpreePos::OrderPush and the real, boot-registered SpreeSquare::Provider
# loaded together. spree_pos's own order_push_spec covers the same service
# against a stub adapter (the bookkeeping/state-machine half); this covers
# the resolution half, which a stub adapter by definition cannot.
#
# Nothing here registers a provider. If SpreeSquare::Engine's boot-time
# registration broke, these fail.
RSpec.describe 'SpreePos::OrderPush registry resolution' do
  let(:order) { create(:order) }
  let!(:connection) { create(:pos_connection, store: order.store, provider: 'square') }
  let!(:pos_location) do
    stock_location = create(:stock_location, store: order.store)
    # Enabled, like every Square location that existed before spree_pos 0.4.0
    # (KeepExistingSquareLocationsPushingOrders). A new one starts disabled;
    # see the last example.
    mapping = create(:pos_location, :order_push_enabled, pos_connection: connection, stock_location: stock_location)
    create(:shipment, order: order, stock_location: stock_location)
    order.reload
    mapping
  end

  let(:push_result) do
    SpreePos::Orders::PushResult.new(
      external_order_id: 'sq_order_1',
      external_payment_id: 'sq_payment_1',
      external_location_id: 'sq_loc_1',
      external_version: 3,
      status: 'COMPLETED'
    )
  end

  it 'resolves the Square order adapter from the connection, with no adapter injected' do
    expect_any_instance_of(SpreeSquare::OrderAdapter).to receive(:push).with(order).and_return(push_result)

    mapping = described_class_call

    expect(mapping.external_order_id).to eq('sq_order_1')
    expect(mapping.push_state).to eq('succeeded')
    expect(mapping.pos_connection).to eq(connection)
    expect(mapping.pos_location).to eq(pos_location)
  end

  it 'asks the registry for the provider the connection names' do
    allow_any_instance_of(SpreeSquare::OrderAdapter).to receive(:push).and_return(push_result)

    expect(SpreePos).to receive(:provider).with('square').and_call_original

    described_class_call
  end

  it 'takes :order_idempotency_key from the resolved provider, landing a failed push in `failed`' do
    # Square declares :order_idempotency_key, so a raised push must mark
    # the mapping `failed` (safely retryable) and NOT `ambiguous`. The
    # caller no longer asserts this on Square's behalf — the capability
    # does. This is the exact Gate B behaviour, now capability-driven.
    expect(SpreeSquare::Provider).to be_supports(:order_idempotency_key)
    allow_any_instance_of(SpreeSquare::OrderAdapter).to receive(:push).and_raise(StandardError, 'boom')

    expect { described_class_call }.to raise_error(StandardError, 'boom')

    mapping = SpreePos::OrderMapping.find_by(order: order)
    expect(mapping.push_state).to eq('failed')
    expect(mapping.push_state).not_to eq('ambiguous')
  end

  it 'does not push at all when the connection names a provider that is not registered' do
    connection.update!(provider: 'nonexistent')
    allow(SpreePos::Alerting).to receive(:capture)

    expect_any_instance_of(SpreeSquare::OrderAdapter).not_to receive(:push)
    expect(SpreePos::Alerting).to receive(:capture).with(
      instance_of(SpreePos::PermanentError), context: hash_including(area: 'order_push')
    )

    expect(described_class_call).to be_nil
    expect(SpreePos::OrderMapping.find_by(order: order)).to be_nil
  end

  def described_class_call
    SpreePos::OrderPush.call(order)
  end

  it 'never reaches the Square adapter for a location whose order pushing is disabled' do
    SpreePos::OrderPushActivation.disable!(pos_location, actor: 'spec')
    expect_any_instance_of(SpreeSquare::OrderAdapter).not_to receive(:push)

    expect(described_class_call).to be_a(SpreePos::OrderPush::Refused)
    expect(SpreePos::OrderMapping.where(order: order)).to be_empty
  end
end
