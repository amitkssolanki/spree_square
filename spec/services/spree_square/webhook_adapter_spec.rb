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
    it 'delegates to the Client instance webhook signature key' do
      client = instance_double(SpreeSquare::Client, webhook_signature_key: 'the-key')
      allow(SpreeSquare::Client).to receive(:instance).and_return(client)

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

  describe '.parse' do
    it 'returns the idempotency_key, kind and event_type generically' do
      payload = { 'event_id' => 'evt_1', 'type' => 'catalog.version.updated' }

      expect(described_class.parse(payload)).to eq(
        idempotency_key: 'evt_1',
        kind: 'catalog_changed',
        event_type: 'catalog.version.updated'
      )
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
