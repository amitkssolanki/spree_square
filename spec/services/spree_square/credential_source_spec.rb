require 'json'

# Square has exactly one runtime credential source: SpreeSquare::Credential.
# SpreePos::Connection carries the same columns because Clover's connections
# ARE its credential's home, and Phase 3 copied Square's onto the connection
# for a move that has not happened. That copy drifted in production the first
# time the token refreshed (2026-09-12), so a migration clears it and these
# specs keep it from coming back.
RSpec.describe 'the Square credential source of truth' do
  let(:store) { Spree::Store.default.presence || create(:store) }
  let!(:connection) do
    SpreePos::Connection.create!(store: store, provider: 'square', external_merchant_id: 'sq_merchant_1',
                                  catalog_role: 'source', status: 'active')
  end

  # Without these, OauthClient's constructor raises ConfigurationError and
  # refresh_if_needed! swallows it, so a broken refresh would look like a
  # credential that simply never changed.
  around do |example|
    original = ENV.to_h.slice('SQUARE_APPLICATION_ID', 'SQUARE_APPLICATION_SECRET', 'SQUARE_ENVIRONMENT')
    ENV['SQUARE_APPLICATION_ID'] = 'sandbox-app-id'
    ENV['SQUARE_APPLICATION_SECRET'] = 'app-secret'
    ENV['SQUARE_ENVIRONMENT'] = 'sandbox'
    example.run
    ENV['SQUARE_APPLICATION_ID'] = original['SQUARE_APPLICATION_ID']
    ENV['SQUARE_APPLICATION_SECRET'] = original['SQUARE_APPLICATION_SECRET']
    ENV['SQUARE_ENVIRONMENT'] = original['SQUARE_ENVIRONMENT']
  end

  it 'authenticates with the credential even when a connection carries a different token' do
    create(:square_credential, store: store, access_token: 'the-credential-token', expires_at: 20.days.from_now)
    connection.update!(access_token: 'a-stale-connection-token')
    captured = nil
    allow(Square::Client).to receive(:new) { |**kwargs| captured = kwargs[:token]; instance_double(Square::Client) }

    SpreeSquare::Client.for_store(store)

    expect(captured).to eq('the-credential-token')
  end

  it 'refreshes into the credential and leaves the connection alone' do
    credential = create(:square_credential, store: store, access_token: 'stale', refresh_token: 'refresh-me',
                                            expires_at: 3.days.from_now)
    stub_request(:post, 'https://connect.squareupsandbox.com/oauth2/token')
      .with(body: hash_including('grant_type' => 'refresh_token', 'refresh_token' => 'refresh-me'))
      .to_return(
        status: 200, headers: { 'Content-Type' => 'application/json' },
        body: { access_token: 'fresh-token', refresh_token: 'refresh-me', expires_at: 30.days.from_now.iso8601 }.to_json
      )
    # The rescue in refresh_if_needed! logs and carries on, so assert here too:
    # a refresh that fails must not read as "the credential just didn't move".
    expect(SpreePos::Alerting).not_to receive(:capture)

    SpreeSquare::Client.for_store(store)

    expect(credential.reload.access_token).to eq('fresh-token')
    expect(connection.reload.access_token).to be_nil
  end

  # A source-level guard, because the drift this prevents is a READ or a WRITE
  # someone adds later, not a behaviour today's specs would cover.
  it 'never reads or writes a connection credential column anywhere in this gem' do
    files = Dir.glob([File.join(SpreeSquare::Engine.root, 'app/**/*.rb'), File.join(SpreeSquare::Engine.root, 'lib/**/*.rb')])
    offenders = files.filter_map do |file|
      lines = File.readlines(file).each_with_index.select do |line, _|
        # Strip comments first: the point is real reads and writes, and
        # webhook_adapter.rb documents in prose why it does NOT consult
        # connection.webhook_secret.
        code = line.sub(/(\A|\s)#.*/m, '')
        code.match?(/(connection|conn)\s*(\.|\[:)\s*(access_token|refresh_token|webhook_secret|refresh_token_expires_at)/)
      end
      "#{file.sub("#{SpreeSquare::Engine.root}/", '')}: #{lines.map { |_, i| i + 1 }.join(', ')}" if lines.any?
    end

    expect(offenders).to be_empty,
                         "Square's credential lives in SpreeSquare::Credential. These read or write the " \
                         "connection's copy instead:\n#{offenders.join("\n")}"
  end
end
