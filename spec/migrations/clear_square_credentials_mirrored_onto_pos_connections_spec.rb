require File.join(SpreeSquare::Engine.root, 'db/migrate/20260912000001_clear_square_credentials_mirrored_onto_pos_connections')

# This migration edits production rows, so it is covered like code: what it
# clears, and the two cases it must not touch.
RSpec.describe ClearSquareCredentialsMirroredOntoPosConnections do
  subject(:migration) { described_class.new }

  let(:store) { Spree::Store.default.presence || create(:store) }

  around do |example|
    original = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
    example.run
    ActiveRecord::Migration.verbose = original
  end

  def connection_for(provider, **attributes)
    SpreePos::Connection.create!(
      { store: store, provider: provider, external_merchant_id: "#{provider}_merchant", catalog_role: 'none',
        status: 'active', access_token: 'mirrored-access', refresh_token: 'mirrored-refresh',
        expires_at: 5.days.from_now, refresh_token_expires_at: 20.days.from_now,
        webhook_secret: 'mirrored-secret' }.merge(attributes)
    )
  end

  it 'clears the mirrored credential from a Square connection whose store still has the real one' do
    create(:square_credential, store: store, access_token: 'the-real-token', expires_at: 30.days.from_now)
    connection = connection_for('square')

    migration.up

    connection.reload
    expect(connection.access_token).to be_nil
    expect(connection.refresh_token).to be_nil
    expect(connection.expires_at).to be_nil
    expect(connection.refresh_token_expires_at).to be_nil
    expect(connection.webhook_secret).to be_nil
  end

  it 'leaves the rest of the connection intact: it clears a secret, it does not disconnect anything' do
    create(:square_credential, store: store, expires_at: 30.days.from_now)
    connection = connection_for('square', status: 'active', connected_at: 2.days.ago, scopes: %w[ITEMS_READ])

    expect { migration.up }.not_to change { connection.reload.attributes.slice('status', 'connected_at', 'scopes', 'external_merchant_id') }
  end

  it 'never clears the only copy: a Square connection whose store has no SpreeSquare::Credential is left alone' do
    connection = connection_for('square')

    expect { migration.up }.not_to change { connection.reload.access_token }
    expect(connection.webhook_secret).to eq('mirrored-secret')
  end

  it 'does not touch another provider, whose connection IS the credential' do
    create(:square_credential, store: store, expires_at: 30.days.from_now)
    clover = connection_for('clover')

    migration.up

    clover.reload
    expect(clover.access_token).to eq('mirrored-access')
    expect(clover.webhook_secret).to eq('mirrored-secret')
  end

  it 'does not touch SpreeSquare::Credential, the source it is preserving' do
    credential = create(:square_credential, store: store, access_token: 'the-real-token', expires_at: 30.days.from_now)
    connection_for('square')

    expect { migration.up }.not_to change { credential.reload.access_token }
  end

  it 'refuses to roll back, because the cleared values were a stale copy' do
    expect { migration.down }.to raise_error(ActiveRecord::IrreversibleMigration, /reconnect Square/)
  end
end
