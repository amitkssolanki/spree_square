# End-to-end coverage for the new provider-neutral endpoint (plan 15.1):
#
#   POST /spree_pos/webhooks/:provider
#
# Lives in spree_square's spec suite (not spree_pos's) because it needs
# both SpreePos::WebhooksController and SpreeSquare::WebhookAdapter loaded
# together — spree_pos's own dummy app has no Square adapter at all. The
# FakeSquareProviderForWebhookRouting registration in spec/support stands
# in for the real SpreeSquare::Provider registration, which does not exist
# anywhere in this codebase yet (see this batch's report) — without
# *something* registered under :square, SpreePos.provider('square') raises
# ArgumentError and every request here would 404 regardless of signature.
#
# Behaviourally this mirrors spec/requests/spree_square/webhooks_controller_spec.rb
# (the legacy route) exactly, because both routes end up calling the exact
# same #handle_square path.
RSpec.describe 'SpreePos webhooks (new route, square)', type: :request do
  let(:signing_key) { 'test-signing-key' }
  let(:path) { '/spree_pos/webhooks/square' }
  let(:body) { { event_id: 'evt_1', type: 'catalog.version.updated', data: {} }.to_json }

  before do
    client = instance_double(SpreeSquare::Client, webhook_signature_key: signing_key)
    allow(SpreeSquare::Client).to receive(:instance).and_return(client)
    SpreePos.register(FakeSquareProviderForWebhookRouting)
  end

  after { SpreePos.providers.delete(:square) }

  def signed_headers(body, url: "http://www.example.com#{path}")
    digest = OpenSSL::HMAC.digest('sha256', signing_key, "#{url}#{body}")
    signature = Base64.strict_encode64(digest)
    { 'x-square-hmacsha256-signature' => signature, 'CONTENT_TYPE' => 'application/json' }
  end

  it 'accepts a correctly signed payload and enqueues the shared webhook job' do
    expect(SpreePos::CatalogWebhookJob).to receive(:perform_later)

    post path, params: body, headers: signed_headers(body)

    expect(response).to have_http_status(:ok)
    expect(SpreePos::WebhookEvent.find_by(provider: 'square', idempotency_key: 'evt_1')).to be_present
  end

  it 'rejects a request with an invalid signature' do
    post path, params: body, headers: { 'x-square-hmacsha256-signature' => 'wrong', 'CONTENT_TYPE' => 'application/json' }

    expect(response).to have_http_status(:unauthorized)
    expect(SpreePos::WebhookEvent.find_by(provider: 'square', idempotency_key: 'evt_1')).to be_nil
  end

  it 'does not enqueue a job twice for a duplicate delivery of the same event_id' do
    expect(SpreePos::CatalogWebhookJob).to receive(:perform_later).once

    2.times { post path, params: body, headers: signed_headers(body) }

    expect(response).to have_http_status(:ok)
    expect(SpreePos::WebhookEvent.where(provider: 'square', idempotency_key: 'evt_1').count).to eq(1)
  end

  it 'returns 400 for a body that is not valid JSON' do
    broken_body = '{not json'

    post path, params: broken_body, headers: signed_headers(broken_body)

    expect(response).to have_http_status(:bad_request)
  end

  it 'the legacy route and the new route record the exact same SpreePos::WebhookEvent shape' do
    post path, params: body, headers: signed_headers(body)
    new_route_event = SpreePos::WebhookEvent.find_by!(provider: 'square', idempotency_key: 'evt_1')

    legacy_body = { event_id: 'evt_legacy', type: 'catalog.version.updated', data: {} }.to_json
    legacy_headers = signed_headers(legacy_body, url: 'http://www.example.com/spree_square/webhooks/square')
    post '/spree_square/webhooks/square', params: legacy_body, headers: legacy_headers
    legacy_route_event = SpreePos::WebhookEvent.find_by!(provider: 'square', idempotency_key: 'evt_legacy')

    expect(new_route_event.kind).to eq(legacy_route_event.kind)
    expect(new_route_event.event_type).to eq(legacy_route_event.event_type)
  end
end
