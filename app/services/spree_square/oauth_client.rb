# Bundler's gem-name-based auto-require doesn't resolve "square.rb" -> "square"
# (the gem's require path), so it's not auto-required by Bundler.require —
# see SpreeSquare::Client for the same note.
require 'square'
require 'net/http'

module SpreeSquare
  # The OAuth half of talking to Square — separate from SpreeSquare::Client
  # (which makes authenticated Catalog/Orders/Payments calls with a token
  # already in hand). This class is how that token gets obtained, refreshed,
  # and revoked in the first place.
  #
  # Scopes requested cover every API spree_square actually calls elsewhere
  # (Client#catalog/orders/payments/inventory/locations/webhooks) — keep this
  # list in sync if a new Square API surface gets used.
  class OauthClient
    class ConfigurationError < StandardError; end

    SCOPES = %w[
      MERCHANT_PROFILE_READ
      ITEMS_READ
      INVENTORY_READ
      INVENTORY_WRITE
      ORDERS_READ
      ORDERS_WRITE
      PAYMENTS_WRITE
      PAYMENTS_READ
    ].freeze

    def self.authorize_url(...) = new.authorize_url(...)
    def self.exchange_code(...) = new.exchange_code(...)
    def self.refresh(...) = new.refresh(...)
    def self.revoke(...) = new.revoke(...)

    def initialize
      @application_id = ENV['SQUARE_APPLICATION_ID'].presence
      @application_secret = ENV['SQUARE_APPLICATION_SECRET'].presence
      raise ConfigurationError, 'SQUARE_APPLICATION_ID is not set' if @application_id.blank?
      raise ConfigurationError, 'SQUARE_APPLICATION_SECRET is not set' if @application_secret.blank?
    end

    # The URL to send the merchant's browser to. `session: false` forces
    # Square to show its account chooser even if the browser is already
    # signed in to a Square account — without it, a staff member testing
    # this on a shared machine could silently connect the wrong account.
    def authorize_url(redirect_uri:, state:)
      params = {
        client_id: @application_id,
        scope: SCOPES.join(' '),
        session: false,
        state: state,
        redirect_uri: redirect_uri
      }
      "#{base_url}/oauth2/authorize?#{params.to_query}"
    end

    def exchange_code(code:, redirect_uri:)
      oauth_api.obtain_token(
        client_id: @application_id,
        client_secret: @application_secret,
        code: code,
        grant_type: 'authorization_code',
        redirect_uri: redirect_uri
      )
    end

    # Code-flow refresh (vs. PKCE) returns the *same* refresh token back —
    # Square's docs call this out explicitly, so callers should always save
    # whatever comes back here rather than assuming the old one still works.
    def refresh(credential)
      oauth_api.obtain_token(
        client_id: @application_id,
        client_secret: @application_secret,
        refresh_token: credential.refresh_token,
        grant_type: 'refresh_token'
      )
    end

    # Square's RevokeToken endpoint doesn't use the normal `Bearer <token>`
    # scheme every other call in this extension uses — it requires
    # `Authorization: Client <application_secret>` instead, which the SDK's
    # Square::Client can't produce (its Authorization header is fixed to
    # Bearer at construction). Raw HTTP here, deliberately not routed
    # through the SDK.
    def revoke(credential)
      uri = URI("#{base_url}/oauth2/revoke")
      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request['Authorization'] = "Client #{@application_secret}"
      request.body = { client_id: @application_id, access_token: credential.access_token }.to_json

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
      return if response.is_a?(Net::HTTPSuccess)

      raise Square::Errors::ResponseError.subclass_for_code(response.code.to_i).new(response.body, code: response.code.to_i)
    end

    private

    # A bearer token isn't needed for any of oauth2/authorize, oauth2/token,
    # or oauth2/revoke (the latter uses the Client-secret scheme above
    # instead) — passing `token: nil` here just produces an unused,
    # harmless `Authorization: Bearer ` header on the token-exchange/refresh
    # calls, which those endpoints ignore.
    def oauth_api
      @oauth_api ||= Square::Client.new(base_url: base_url, token: nil).o_auth
    end

    def base_url
      sandbox? ? Square::Environment::SANDBOX : Square::Environment::PRODUCTION
    end

    def sandbox?
      ENV.fetch('SQUARE_ENVIRONMENT', 'sandbox') == 'sandbox'
    end
  end
end
