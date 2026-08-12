RSpec.describe SpreeSquare::OauthClient do
  around do |example|
    original = ENV.to_h.slice('SQUARE_APPLICATION_ID', 'SQUARE_APPLICATION_SECRET', 'SQUARE_ENVIRONMENT')
    ENV['SQUARE_APPLICATION_ID'] = 'sandbox-app-id'
    ENV['SQUARE_APPLICATION_SECRET'] = 'app-secret'
    ENV['SQUARE_ENVIRONMENT'] = 'sandbox'
    example.run
    original.each { |k, v| ENV[k] = v }
  end

  it 'raises a clear error when SQUARE_APPLICATION_SECRET is missing' do
    ENV['SQUARE_APPLICATION_SECRET'] = nil

    expect { described_class.new }.to raise_error(described_class::ConfigurationError, /SQUARE_APPLICATION_SECRET/)
  end

  it 'raises a clear error when SQUARE_APPLICATION_ID is missing' do
    ENV['SQUARE_APPLICATION_ID'] = nil

    expect { described_class.new }.to raise_error(described_class::ConfigurationError, /SQUARE_APPLICATION_ID/)
  end

  describe '#authorize_url' do
    it 'points at the sandbox host and carries every required OAuth param' do
      url = described_class.authorize_url(redirect_uri: 'https://example.com/callback', state: 'csrf-token-123')
      uri = URI.parse(url)
      params = URI.decode_www_form(uri.query).to_h

      expect(uri.host).to eq('connect.squareupsandbox.com')
      expect(uri.path).to eq('/oauth2/authorize')
      expect(params['client_id']).to eq('sandbox-app-id')
      expect(params['redirect_uri']).to eq('https://example.com/callback')
      expect(params['state']).to eq('csrf-token-123')
      expect(params['session']).to eq('false')
      expect(params['scope']).to eq(described_class::SCOPES.join(' '))
    end

    it 'points at the production host once SQUARE_ENVIRONMENT is production' do
      ENV['SQUARE_ENVIRONMENT'] = 'production'

      uri = URI.parse(described_class.authorize_url(redirect_uri: 'https://example.com/callback', state: 's'))

      expect(uri.host).to eq('connect.squareup.com')
    end
  end

  describe '.exchange_code' do
    it 'exchanges an authorization code for an access and refresh token' do
      stub_request(:post, 'https://connect.squareupsandbox.com/oauth2/token')
        .with(body: hash_including('grant_type' => 'authorization_code', 'code' => 'auth-code-abc', 'client_id' => 'sandbox-app-id', 'client_secret' => 'app-secret'))
        .to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: {
            access_token: 'new-access-token',
            refresh_token: 'new-refresh-token',
            merchant_id: 'MERCHANT_1',
            expires_at: 30.days.from_now.iso8601
          }.to_json
        )

      response = described_class.exchange_code(code: 'auth-code-abc', redirect_uri: 'https://example.com/callback')

      expect(response.access_token).to eq('new-access-token')
      expect(response.refresh_token).to eq('new-refresh-token')
      expect(response.merchant_id).to eq('MERCHANT_1')
    end
  end

  describe '.refresh' do
    it 'requests a new access token using the credential\'s stored refresh token' do
      credential = build(:square_credential, refresh_token: 'stored-refresh-token')

      stub_request(:post, 'https://connect.squareupsandbox.com/oauth2/token')
        .with(body: hash_including('grant_type' => 'refresh_token', 'refresh_token' => 'stored-refresh-token'))
        .to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: { access_token: 'refreshed-token', refresh_token: 'stored-refresh-token', expires_at: 30.days.from_now.iso8601 }.to_json
        )

      response = described_class.refresh(credential)

      expect(response.access_token).to eq('refreshed-token')
    end
  end

  describe '.revoke' do
    it 'authenticates with the application secret via the Client scheme, not Bearer' do
      credential = build(:square_credential, access_token: 'token-to-revoke')

      stub = stub_request(:post, 'https://connect.squareupsandbox.com/oauth2/revoke')
        .with(
          headers: { 'Authorization' => 'Client app-secret' },
          body: hash_including('access_token' => 'token-to-revoke')
        )
        .to_return(status: 200, headers: { 'Content-Type' => 'application/json' }, body: '{"success":true}')

      described_class.revoke(credential)

      expect(stub).to have_been_requested
    end

    it 'raises when Square rejects the revoke request' do
      credential = build(:square_credential, access_token: 'token-to-revoke')

      stub_request(:post, 'https://connect.squareupsandbox.com/oauth2/revoke')
        .to_return(status: 401, headers: { 'Content-Type' => 'application/json' }, body: '{"errors":[{"code":"UNAUTHORIZED"}]}')

      expect { described_class.revoke(credential) }.to raise_error(Square::Errors::ResponseError)
    end
  end
end
