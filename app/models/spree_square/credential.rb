module SpreeSquare
  # A Square OAuth connection for one Spree::Store. Replaces the
  # SQUARE_ACCESS_TOKEN env var with a per-store, self-service "Connect to
  # Square" flow (see SpreeSquare::OauthClient and
  # Spree::Admin::SquareOauthController) — the access-token mechanism Square
  # requires multi-merchant apps to move away from before listing on the App
  # Marketplace (personal access tokens are explicitly disallowed there).
  #
  # `access_token`/`refresh_token` are encrypted at rest (ActiveRecord::
  # Encryption — see config/initializers/active_record_encryption.rb); Square
  # tokens expire every 30 days and Square recommends refreshing every 7 or
  # fewer, hence REFRESH_BUFFER below.
  class Credential < Spree.base_class
    self.table_name = 'spree_square_credentials'

    REFRESH_BUFFER = 7.days

    belongs_to :store, class_name: 'Spree::Store'

    encrypts :access_token, :refresh_token

    validates :store, presence: true, uniqueness: true
    validates :square_merchant_id, presence: true, uniqueness: true

    def sandbox?
      square_environment == 'sandbox'
    end

    def expired?
      expires_at.present? && expires_at <= Time.current
    end

    # True once we're inside Square's recommended refresh window — checked
    # before every API call (see SpreeSquare::Client#ensure_fresh!) rather
    # than on a schedule, so a credential that's gone briefly unused still
    # gets refreshed the moment it's needed again.
    def needs_refresh?
      expires_at.present? && expires_at <= REFRESH_BUFFER.from_now
    end
  end
end
