# Characterization spec for the legacy `/spree_square/webhooks/square`
# endpoint (plan 15.5: it "cannot change without an operator action" and
# must "keep working exactly as before"). Retargeted from
# SpreeSquare::WebhookEvent (square_event_id) onto SpreePos::WebhookEvent
# (idempotency_key) — same assertions as before this batch, only the model
# and column names changed. `SpreePos::WebhooksController#enqueue_job`
# dispatches per `event.kind` to the real spree_pos job classes (plan
# sequence step 18) -- wired at integration once both step 17 (this
# controller) and step 18 (those job classes) landed; see
# spec/requests/spree_pos/webhooks_controller_spec.rb in the spree_pos gem
# for the routing/verification specs shared with the new
# `/spree_pos/webhooks/:provider` endpoint.
RSpec.describe 'SpreeSquare webhooks (legacy route)', type: :request do
  let(:signing_key) { 'test-signing-key' }
  let(:path) { '/spree_square/webhooks/square' }
  let(:body) { { event_id: 'evt_1', type: 'catalog.version.updated', data: {} }.to_json }

  before do
    # SpreeSquare::Client.instance initializes a real Square::Client and
    # raises MissingCredentialsError without a configured access token —
    # stub the class method itself rather than touching the real singleton,
    # so this spec needs no Square credentials at all.
    client = instance_double(SpreeSquare::Client, webhook_signature_key: signing_key)
    allow(SpreeSquare::Client).to receive(:instance).and_return(client)
  end

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

  it 'rejects a request with no signature header at all' do
    post path, params: body, headers: { 'CONTENT_TYPE' => 'application/json' }

    expect(response).to have_http_status(:unauthorized)
  end

  it 'does not enqueue a job twice for a duplicate delivery of the same event_id' do
    expect(SpreePos::CatalogWebhookJob).to receive(:perform_later).once

    2.times { post path, params: body, headers: signed_headers(body) }

    expect(response).to have_http_status(:ok)
    expect(SpreePos::WebhookEvent.where(provider: 'square', idempotency_key: 'evt_1').count).to eq(1)
  end

  it 'acknowledges an unrecognized event type without enqueuing anything' do
    unknown_body = { event_id: 'evt_unknown', type: 'some.future.event', data: {} }.to_json

    post path, params: unknown_body, headers: signed_headers(unknown_body)

    expect(response).to have_http_status(:ok)
    event = SpreePos::WebhookEvent.find_by(provider: 'square', idempotency_key: 'evt_unknown')
    expect(event).to be_present
    expect(event.kind).to eq('unknown')
  end

  it 'returns 400 for a body that is not valid JSON' do
    broken_body = '{not json'

    post path, params: broken_body, headers: signed_headers(broken_body)

    expect(response).to have_http_status(:bad_request)
  end

  %w[inventory.count.updated order.updated order.fulfillment.updated].each do |event_type|
    it "records #{event_type} with the right kind and enqueues the shared job" do
      expected_kind = {
        'inventory.count.updated' => 'inventory_changed',
        'order.updated' => 'order_changed',
        'order.fulfillment.updated' => 'order_changed'
      }.fetch(event_type)
      expected_job = {
        'inventory.count.updated' => SpreePos::InventoryWebhookJob,
        'order.updated' => SpreePos::OrderWebhookJob,
        'order.fulfillment.updated' => SpreePos::OrderWebhookJob
      }.fetch(event_type)
      typed_body = { event_id: "evt_#{event_type}", type: event_type, data: {} }.to_json

      expect(expected_job).to receive(:perform_later)

      post path, params: typed_body, headers: signed_headers(typed_body)

      expect(response).to have_http_status(:ok)
      event = SpreePos::WebhookEvent.find_by(provider: 'square', idempotency_key: "evt_#{event_type}")
      expect(event.kind).to eq(expected_kind)
    end
  end
end
