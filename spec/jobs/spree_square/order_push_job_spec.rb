RSpec.describe SpreeSquare::OrderPushJob do
  let(:order) { create(:order, state: 'complete', completed_at: Time.current) }

  describe '#perform' do
    # Package A: this job no longer injects a Square adapter or asserts
    # Square's idempotency capability on its behalf. It hands the order to
    # the provider-neutral service, which resolves both through the
    # registry from the connection behind the order's fulfilling location.
    # The adapter/capability resolution itself is covered in
    # spec/services/spree_pos/order_push_registry_spec.rb.
    it 'hands the order to the provider-neutral SpreePos::OrderPush with no injected adapter' do
      expect(SpreePos::OrderPush).to receive(:call).with(order)

      described_class.perform_now(order.id)
    end
  end

  describe 'when retries are exhausted' do
    # This is the one failure mode called out in the job's own comment as
    # the worst in the system (payment taken, kitchen never sees it) — so
    # it gets its own coverage of exactly what happens on the record and
    # what gets alerted, not just that *something* is alerted.
    it 'records the failure on an existing OrderMapping and alerts with the order number' do
      # Simulates the real call chain's own ordering: SpreePos::OrderPush#call
      # always creates the mapping (with a real connection/location already
      # set) BEFORE ever calling the adapter -- so by the time an adapter
      # failure exhausts retries, a mapping already exists here. `.call` is
      # still stubbed for isolation; the mapping is created directly to
      # stand in for that already-completed first step.
      # `:pos_order_mapping` isn't registered in this gem's own spec suite
      # (spree_square/spec/rails_helper.rb only requires spree_square's own
      # factories) -- constructed directly instead.
      connection = SpreePos::Connection.create!(store: order.store, provider: 'square',
                                                  external_merchant_id: 'sq_merchant_1', catalog_role: 'source')
      stock_location = create(:stock_location, store: order.store)
      pos_location = SpreePos::Location.create!(pos_connection: connection, stock_location: stock_location,
                                                  external_location_id: 'sq_location_1')
      SpreePos::OrderMapping.create!(order: order, pos_connection: connection, pos_location: pos_location)
      allow(SpreePos::OrderPush).to receive(:call).and_raise(StandardError, 'square is down')
      expect(SpreePos::Alerting).to receive(:capture).with(
        instance_of(StandardError),
        context: { area: 'order_push', order_number: order.number }
      )

      job = described_class.new(order.id)
      job.exception_executions = { '[StandardError]' => 4 }

      expect { job.perform_now }.not_to raise_error

      mapping = SpreePos::OrderMapping.find_by(order: order)
      expect(mapping.push_error).to include('square is down')
    end

    # Phase 3, this session's write-path audit: found and fixed a real bug
    # here. spree_pos_order_mappings.pos_connection_id/pos_location_id are
    # NOT NULL after the tighten migration, so building a BRAND NEW mapping
    # in this handler (the old `find_or_initialize_by(order: order)`) would
    # try to `save!` one with both nil, raising ActiveRecord::NotNullViolation
    # from inside this exception handler itself -- which would also have
    # silently swallowed the `Alerting.capture` call below it, the one alert
    # this class's own comment says "should always reach a human regardless
    # of Sentry config." Now uses `find_by` (never creates), so this no-ops
    # cleanly and the alert still fires.
    it 'still alerts, and creates no connection-less OrderMapping, when no mapping exists yet at exhaustion time' do
      allow(SpreePos::OrderPush).to receive(:call).and_raise(StandardError, 'square is down')
      expect(SpreePos::Alerting).to receive(:capture).with(
        instance_of(StandardError),
        context: { area: 'order_push', order_number: order.number }
      )

      job = described_class.new(order.id)
      job.exception_executions = { '[StandardError]' => 4 }

      expect { job.perform_now }.not_to raise_error
      expect(SpreePos::OrderMapping.where(order: order)).not_to exist
    end

    it 'still alerts (without a mapping) when the order itself can no longer be found' do
      order_id = order.id
      order.destroy
      expect(SpreePos::OrderPush).not_to receive(:call)

      # retry_on's exhaustion counter is keyed by the *declared* exception
      # list (`StandardError`, what the job's retry_on line names) — not by
      # the concrete class actually raised, which here is
      # ActiveRecord::RecordNotFound bubbling out of Spree::Order.find.
      expect(SpreePos::Alerting).to receive(:capture).with(
        instance_of(ActiveRecord::RecordNotFound),
        context: { area: 'order_push', order_number: nil }
      )

      job = described_class.new(order_id)
      job.exception_executions = { '[StandardError]' => 4 }

      expect { job.perform_now }.not_to raise_error
      expect(SpreePos::OrderMapping.count).to eq(0)
    end
  end
end
