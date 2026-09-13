RSpec.describe SpreeSquare::WebhookAdapter do
  describe '.verify' do
    let(:url) { 'https://example.ngrok-free.dev/spree_square/webhooks/square' }
    let(:body) { '{"event_id":"abc-123","type":"order.updated"}' }
    let(:signing_key) { 'test-signing-key' }

    def signature_for(url, body, key)
      digest = OpenSSL::HMAC.digest('sha256', key, "#{url}#{body}")
      Base64.strict_encode64(digest)
    end

    it 'accepts a correctly signed payload' do
      signature = signature_for(url, body, signing_key)

      expect(
        described_class.verify(url: url, body: body, signature: signature, signing_key: signing_key)
      ).to be true
    end

    it 'rejects a tampered body' do
      signature = signature_for(url, body, signing_key)

      expect(
        described_class.verify(url: url, body: "#{body}tampered", signature: signature, signing_key: signing_key)
      ).to be false
    end

    it 'rejects a signature computed with the wrong key' do
      signature = signature_for(url, body, 'wrong-key')

      expect(
        described_class.verify(url: url, body: body, signature: signature, signing_key: signing_key)
      ).to be false
    end

    it 'rejects a signature computed for a different URL' do
      signature = signature_for('https://attacker.example.com/webhook', body, signing_key)

      expect(
        described_class.verify(url: url, body: body, signature: signature, signing_key: signing_key)
      ).to be false
    end

    it 'rejects when the signature is missing' do
      expect(
        described_class.verify(url: url, body: body, signature: nil, signing_key: signing_key)
      ).to be false
    end

    it 'rejects when the signing key is blank' do
      signature = signature_for(url, body, signing_key)

      expect(
        described_class.verify(url: url, body: body, signature: signature, signing_key: '')
      ).to be false
    end

    it 'rejects when the body is nil' do
      expect(
        described_class.verify(url: url, body: nil, signature: 'anything', signing_key: signing_key)
      ).to be false
    end
  end

  describe '.signature_header' do
    it 'is the header Square signs its webhook POSTs with' do
      expect(described_class.signature_header).to eq('x-square-hmacsha256-signature')
    end
  end

  describe '.signing_key' do
    # App-level: resolving it must not build a client for any store (it used
    # to build one for the default store just to read an ENV value).
    it 'reads the app-level signing key without building a store client' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('SQUARE_WEBHOOK_SIGNATURE_KEY').and_return('the-key')
      expect(SpreeSquare::Client).not_to receive(:new)
      expect(SpreeSquare::Client).not_to receive(:instance)

      expect(described_class.signing_key).to eq('the-key')
    end
  end

  describe '.idempotency_key_for' do
    it "returns Square's event_id" do
      expect(described_class.idempotency_key_for('event_id' => 'evt_1')).to eq('evt_1')
    end
  end

  describe '.kind_for' do
    it 'maps catalog.version.updated to catalog_changed' do
      expect(described_class.kind_for('catalog.version.updated')).to eq('catalog_changed')
    end

    it 'maps inventory.count.updated to inventory_changed' do
      expect(described_class.kind_for('inventory.count.updated')).to eq('inventory_changed')
    end

    it 'maps order.updated to order_changed' do
      expect(described_class.kind_for('order.updated')).to eq('order_changed')
    end

    it 'maps order.fulfillment.updated to order_changed' do
      expect(described_class.kind_for('order.fulfillment.updated')).to eq('order_changed')
    end

    it 'maps anything else to unknown' do
      expect(described_class.kind_for('some.future.event')).to eq('unknown')
    end
  end

  # Was `.parse`, which returned one hash per delivery. The neutral
  # contract is now `.extract_events` returning zero or more
  # SpreePos::Webhooks::Event values, because a provider may batch several
  # merchants into one POST. Square never does, so this always returns
  # exactly one, and the fields it resolved before are unchanged.
  describe '.extract_events' do
    it 'returns exactly one event, since Square sends one per delivery' do
      payload = { 'event_id' => 'evt_1', 'type' => 'catalog.version.updated' }

      events = described_class.extract_events(payload)

      expect(events.size).to eq(1)
      expect(events.first).to be_a(SpreePos::Webhooks::Event)
    end

    it 'resolves the idempotency_key, kind and event_type generically' do
      payload = { 'event_id' => 'evt_1', 'type' => 'catalog.version.updated' }

      event = described_class.extract_events(payload).first

      expect(event.idempotency_key).to eq('evt_1')
      expect(event.kind).to eq('catalog_changed')
      expect(event.event_type).to eq('catalog.version.updated')
    end

    # Tenant routing. Square names the merchant on every event; the
    # controller resolves it to a SpreePos::Connection.
    it 'carries the merchant id so the event can be routed to a connection' do
      payload = { 'event_id' => 'evt_1', 'type' => 'order.updated', 'merchant_id' => 'MERCH_1' }

      expect(described_class.extract_events(payload).first.external_merchant_id).to eq('MERCH_1')
    end

    it "carries the location id when the event names one, so a franchise's event reaches the right restaurant" do
      payload = { 'event_id' => 'evt_1', 'type' => 'order.updated',
                  'data' => { 'id' => 'ord_1', 'object' => { 'location_id' => 'LOC_1' } } }

      event = described_class.extract_events(payload).first

      expect(event.external_location_id).to eq('LOC_1')
      expect(event.resource_ref).to eq('ord_1')
    end

    it 'leaves the location nil rather than guessing when the event names none' do
      payload = { 'event_id' => 'evt_1', 'type' => 'catalog.version.updated' }

      expect(described_class.extract_events(payload).first.external_location_id).to be_nil
    end

    # `raw` is the slice of the delivery this event describes. With one
    # event per delivery that is the whole payload, which is what
    # SpreePos::OrderWebhookJob goes on handing to extract_order_status.
    it 'carries the whole payload as raw, which is what the order job reads' do
      payload = { 'event_id' => 'evt_1', 'type' => 'order.updated' }

      expect(described_class.extract_events(payload).first.raw).to eq(payload)
    end

    it 'parses the event timestamp' do
      payload = { 'event_id' => 'evt_1', 'type' => 'order.updated', 'created_at' => '2026-09-10T12:00:00Z' }

      expect(described_class.extract_events(payload).first.occurred_at).to eq(Time.utc(2026, 9, 10, 12, 0, 0))
    end

    # Losing observability metadata must never cost us the event itself.
    it 'tolerates an unparseable timestamp rather than raising' do
      payload = { 'event_id' => 'evt_1', 'type' => 'order.updated', 'created_at' => 'not a time' }

      expect { described_class.extract_events(payload) }.not_to raise_error
      expect(described_class.extract_events(payload).first.occurred_at).to be_nil
    end
  end

  describe '.extract_order_status' do
    it 'extracts the order-level state from order.updated' do
      payload = {
        'data' => { 'object' => { 'order_updated' => { 'order_id' => 'ord_1', 'version' => 3, 'state' => 'COMPLETED' } } }
      }

      expect(described_class.extract_order_status(payload, 'order.updated')).to eq(
        [{ external_order_id: 'ord_1', version: 3, order_state: 'COMPLETED', fulfillment_state: nil }]
      )
    end

    it 'extracts one entry per fulfillment update from order.fulfillment.updated' do
      payload = {
        'data' => {
          'object' => {
            'order_fulfillment_updated' => {
              'order_id' => 'ord_2',
              'version' => 5,
              'fulfillment_update' => [
                { 'fulfillment_uid' => 'f1', 'new_state' => 'RESERVED', 'old_state' => 'PROPOSED' },
                { 'fulfillment_uid' => 'f2', 'new_state' => 'COMPLETED', 'old_state' => 'PREPARED' }
              ]
            }
          }
        }
      }

      expect(described_class.extract_order_status(payload, 'order.fulfillment.updated')).to eq(
        [
          { external_order_id: 'ord_2', version: 5, order_state: nil, fulfillment_state: 'RESERVED' },
          { external_order_id: 'ord_2', version: 5, order_state: nil, fulfillment_state: 'COMPLETED' }
        ]
      )
    end

    it 'returns an empty array for any other event type' do
      expect(described_class.extract_order_status({}, 'order.something.else')).to eq([])
    end

    it 'returns an empty array when the expected payload keys are missing' do
      expect(described_class.extract_order_status({}, 'order.updated')).to eq(
        [{ external_order_id: nil, version: nil, order_state: nil, fulfillment_state: nil }]
      )
      expect(described_class.extract_order_status({}, 'order.fulfillment.updated')).to eq([])
    end
  end
end
