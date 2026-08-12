RSpec.describe SpreeSquare::WebhookVerifier do
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
      described_class.valid?(url: url, body: body, signature: signature, signing_key: signing_key)
    ).to be true
  end

  it 'rejects a tampered body' do
    signature = signature_for(url, body, signing_key)

    expect(
      described_class.valid?(url: url, body: "#{body}tampered", signature: signature, signing_key: signing_key)
    ).to be false
  end

  it 'rejects a signature computed with the wrong key' do
    signature = signature_for(url, body, 'wrong-key')

    expect(
      described_class.valid?(url: url, body: body, signature: signature, signing_key: signing_key)
    ).to be false
  end

  it 'rejects a signature computed for a different URL' do
    signature = signature_for('https://attacker.example.com/webhook', body, signing_key)

    expect(
      described_class.valid?(url: url, body: body, signature: signature, signing_key: signing_key)
    ).to be false
  end

  it 'rejects when the signature is missing' do
    expect(
      described_class.valid?(url: url, body: body, signature: nil, signing_key: signing_key)
    ).to be false
  end

  it 'rejects when the signing key is blank' do
    signature = signature_for(url, body, signing_key)

    expect(
      described_class.valid?(url: url, body: body, signature: signature, signing_key: '')
    ).to be false
  end

  it 'rejects when the body is nil' do
    expect(
      described_class.valid?(url: url, body: nil, signature: 'anything', signing_key: signing_key)
    ).to be false
  end
end
