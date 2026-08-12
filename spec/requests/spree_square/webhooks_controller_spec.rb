RSpec.describe 'SpreeSquare webhooks', type: :request do
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

  it 'accepts a correctly signed payload and enqueues the matching job' do
    expect(SpreeSquare::CatalogWebhookJob).to receive(:perform_later)

    post path, params: body, headers: signed_headers(body)

    expect(response).to have_http_status(:ok)
    expect(SpreeSquare::WebhookEvent.find_by(square_event_id: 'evt_1')).to be_present
  end

  it 'rejects a request with an invalid signature' do
    post path, params: body, headers: { 'x-square-hmacsha256-signature' => 'wrong', 'CONTENT_TYPE' => 'application/json' }

    expect(response).to have_http_status(:unauthorized)
    expect(SpreeSquare::WebhookEvent.find_by(square_event_id: 'evt_1')).to be_nil
  end

  it 'rejects a request with no signature header at all' do
    post path, params: body, headers: { 'CONTENT_TYPE' => 'application/json' }

    expect(response).to have_http_status(:unauthorized)
  end

  it 'does not enqueue a job twice for a duplicate delivery of the same event_id' do
    expect(SpreeSquare::CatalogWebhookJob).to receive(:perform_later).once

    2.times { post path, params: body, headers: signed_headers(body) }

    expect(response).to have_http_status(:ok)
    expect(SpreeSquare::WebhookEvent.where(square_event_id: 'evt_1').count).to eq(1)
  end

  it 'acknowledges an unrecognized event type without enqueuing anything' do
    unknown_body = { event_id: 'evt_unknown', type: 'some.future.event', data: {} }.to_json

    expect(SpreeSquare::CatalogWebhookJob).not_to receive(:perform_later)
    expect(SpreeSquare::InventoryWebhookJob).not_to receive(:perform_later)
    expect(SpreeSquare::OrderWebhookJob).not_to receive(:perform_later)

    post path, params: unknown_body, headers: signed_headers(unknown_body)

    expect(response).to have_http_status(:ok)
    expect(SpreeSquare::WebhookEvent.find_by(square_event_id: 'evt_unknown')).to be_present
  end

  it 'returns 400 for a body that is not valid JSON' do
    broken_body = '{not json'

    post path, params: broken_body, headers: signed_headers(broken_body)

    expect(response).to have_http_status(:bad_request)
  end

  %w[inventory.count.updated order.updated order.fulfillment.updated].each do |event_type|
    it "routes #{event_type} to its job" do
      job_class = {
        'inventory.count.updated' => SpreeSquare::InventoryWebhookJob,
        'order.updated' => SpreeSquare::OrderWebhookJob,
        'order.fulfillment.updated' => SpreeSquare::OrderWebhookJob
      }.fetch(event_type)
      typed_body = { event_id: "evt_#{event_type}", type: event_type, data: {} }.to_json

      expect(job_class).to receive(:perform_later)

      post path, params: typed_body, headers: signed_headers(typed_body)

      expect(response).to have_http_status(:ok)
    end
  end
end
