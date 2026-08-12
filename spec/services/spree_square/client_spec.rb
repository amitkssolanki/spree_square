RSpec.describe SpreeSquare::Client do
  let(:store) { create(:store) }

  around do |example|
    original = ENV.to_h.slice('SQUARE_ACCESS_TOKEN', 'SQUARE_APPLICATION_ID', 'SQUARE_APPLICATION_SECRET', 'SQUARE_ENVIRONMENT')
    ENV['SQUARE_ACCESS_TOKEN'] = 'env-fallback-token'
    ENV['SQUARE_APPLICATION_ID'] = 'sandbox-app-id'
    ENV['SQUARE_APPLICATION_SECRET'] = 'app-secret'
    ENV['SQUARE_ENVIRONMENT'] = 'sandbox'
    example.run
    original.each { |k, v| ENV[k] = v }
  end

  describe '.for_store' do
    it 'falls back to SQUARE_ACCESS_TOKEN when the store has no connected credential' do
      client = described_class.for_store(store)

      expect(client.send(:resolve_token)).to eq('env-fallback-token')
    end

    it 'uses the connected credential\'s access_token when it is not near expiry' do
      create(:square_credential, store: store, access_token: 'stored-token', expires_at: 20.days.from_now)

      client = described_class.for_store(store)

      expect(client.send(:resolve_token)).to eq('stored-token')
    end

    it 'takes environment (sandbox/production) from the credential, not ENV, once connected' do
      create(:square_credential, store: store, square_environment: 'production', expires_at: 20.days.from_now)
      ENV['SQUARE_ENVIRONMENT'] = 'sandbox'

      client = described_class.for_store(store)

      expect(client).not_to be_sandbox
    end

    it 'refreshes and persists a near-expiry credential before using it' do
      credential = create(:square_credential, store: store, access_token: 'stale-token', refresh_token: 'refresh-me', expires_at: 3.days.from_now)

      stub_request(:post, 'https://connect.squareupsandbox.com/oauth2/token')
        .with(body: hash_including('grant_type' => 'refresh_token', 'refresh_token' => 'refresh-me'))
        .to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: { access_token: 'fresh-token', refresh_token: 'rotated-refresh-token', expires_at: 30.days.from_now.iso8601 }.to_json
        )

      client = described_class.for_store(store)

      expect(client.send(:resolve_token)).to eq('fresh-token')
      credential.reload
      expect(credential.access_token).to eq('fresh-token')
      expect(credential.refresh_token).to eq('rotated-refresh-token')
      expect(credential.expires_at).to be > 25.days.from_now
    end

    it 'falls back to the still-usable access_token when a refresh attempt fails' do
      create(:square_credential, store: store, access_token: 'stale-but-still-valid', refresh_token: 'refresh-me', expires_at: 3.days.from_now)

      stub_request(:post, 'https://connect.squareupsandbox.com/oauth2/token')
        .to_return(status: 500, headers: { 'Content-Type' => 'application/json' }, body: '{"errors":[{"code":"INTERNAL_SERVER_ERROR"}]}')

      client = described_class.for_store(store)

      expect(client.send(:resolve_token)).to eq('stale-but-still-valid')
    end

    it 'raises MissingCredentialsError when neither a credential nor SQUARE_ACCESS_TOKEN exists' do
      ENV['SQUARE_ACCESS_TOKEN'] = nil

      expect { described_class.for_store(store) }.to raise_error(described_class::MissingCredentialsError)
    end
  end

  describe '.instance' do
    it 'resolves against the default store' do
      create(:square_credential, store: Spree::Store.default, access_token: 'default-store-token', expires_at: 20.days.from_now)

      expect(described_class.instance.send(:resolve_token)).to eq('default-store-token')
    end

    it 're-resolves on every call instead of caching a stale pre-connection state' do
      expect(described_class.instance.send(:resolve_token)).to eq('env-fallback-token')

      create(:square_credential, store: Spree::Store.default, access_token: 'newly-connected-token', expires_at: 20.days.from_now)

      expect(described_class.instance.send(:resolve_token)).to eq('newly-connected-token')
    end
  end
end
