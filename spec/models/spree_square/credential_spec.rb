RSpec.describe SpreeSquare::Credential do
  let(:store) { create(:store) }

  it 'encrypts access_token and refresh_token at rest' do
    credential = create(:square_credential, store: store, access_token: 'super-secret-access', refresh_token: 'super-secret-refresh')

    raw_access = ActiveRecord::Base.connection.select_value(
      "SELECT access_token FROM spree_square_credentials WHERE id = #{credential.id}"
    )
    raw_refresh = ActiveRecord::Base.connection.select_value(
      "SELECT refresh_token FROM spree_square_credentials WHERE id = #{credential.id}"
    )

    expect(raw_access).not_to include('super-secret-access')
    expect(raw_refresh).not_to include('super-secret-refresh')
    expect(credential.reload.access_token).to eq('super-secret-access')
    expect(credential.reload.refresh_token).to eq('super-secret-refresh')
  end

  it 'requires at most one credential per store' do
    create(:square_credential, store: store)
    duplicate = build(:square_credential, store: store)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:store]).to be_present
  end

  it 'requires a unique square_merchant_id, even across stores' do
    create(:square_credential, square_merchant_id: 'SHARED_MERCHANT')
    duplicate = build(:square_credential, square_merchant_id: 'SHARED_MERCHANT')

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:square_merchant_id]).to be_present
  end

  describe '#sandbox?' do
    it 'is true for a sandbox-environment credential' do
      expect(build(:square_credential, square_environment: 'sandbox')).to be_sandbox
    end

    it 'is false for a production-environment credential' do
      expect(build(:square_credential, square_environment: 'production')).not_to be_sandbox
    end
  end

  describe '#expired?' do
    it 'is true once expires_at is in the past' do
      expect(build(:square_credential, expires_at: 1.hour.ago)).to be_expired
    end

    it 'is false with no expires_at recorded' do
      expect(build(:square_credential, expires_at: nil)).not_to be_expired
    end

    it 'is false comfortably before expiry' do
      expect(build(:square_credential, expires_at: 20.days.from_now)).not_to be_expired
    end
  end

  describe '#needs_refresh?' do
    it 'is true inside Square\'s recommended refresh window' do
      expect(build(:square_credential, expires_at: 3.days.from_now)).to be_needs_refresh
    end

    it 'is true once already expired' do
      expect(build(:square_credential, expires_at: 1.hour.ago)).to be_needs_refresh
    end

    it 'is false well outside the refresh window' do
      expect(build(:square_credential, expires_at: 20.days.from_now)).not_to be_needs_refresh
    end

    it 'is false with no expires_at recorded' do
      expect(build(:square_credential, expires_at: nil)).not_to be_needs_refresh
    end
  end
end
