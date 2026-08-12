# Bundler's gem-name-based auto-require doesn't resolve "square.rb" -> "square"
# (the gem's require path), so it's not auto-required by Bundler.require.
require 'square'

module SpreeSquare
  # Thin wrapper around Square::Client (the current, Fern-generated SDK —
  # `square.rb` v46+). All Square API access in this extension goes through
  # here so credential lookup and environment selection live in one place.
  #
  # Deliberately NOT using square_legacy's client.orders_api.create_order-style
  # API that most tutorials still show — that's the old SDK shape bundled
  # alongside the new one for migration purposes only.
  #
  # Credential resolution, in order:
  #   1. A SpreeSquare::Credential for the given store (self-service "Connect
  #      to Square" via OAuth — see SpreeSquare::OauthClient) — refreshed
  #      first if it's inside Square's recommended renewal window.
  #   2. SQUARE_ACCESS_TOKEN from ENV — the original single-tenant path, kept
  #      so existing sandbox/dev setups (and anyone not yet using OAuth)
  #      don't break. Square disallows this path for real multi-merchant use
  #      ("partner developers must not request nor use personal access
  #      tokens from the sellers who use their application") — it's a dev
  #      convenience here, not the production story.
  class Client
    class MissingCredentialsError < StandardError; end

    # Deliberately NOT memoized: this used to be `@instance ||= new`, but
    # once a store can connect via OAuth mid-process (an admin clicking
    # "Connect to Square" while Puma/Solid Queue keep running), caching the
    # first resolution forever means every job in that process would keep
    # using the stale pre-connection state until a restart. The lookup this
    # re-does each call is one indexed `SpreeSquare::Credential` query — not
    # worth trading correctness for.
    def self.instance
      for_store
    end

    def self.for_store(store = Spree::Store.default)
      new(credential: SpreeSquare::Credential.find_by(store: store))
    end

    def initialize(credential: nil)
      @credential = credential
      token = resolve_token
      raise MissingCredentialsError, 'No Square credential connected and SQUARE_ACCESS_TOKEN is not set' if token.blank?

      @client = Square::Client.new(base_url: base_url, token: token)
    end

    def catalog = @client.catalog
    def orders = @client.orders
    def payments = @client.payments
    def inventory = @client.inventory
    def locations = @client.locations
    def webhooks = @client.webhooks

    def location_id
      fetch(:location_id, env_key: 'SQUARE_LOCATION_ID')
    end

    # App-level, not per-merchant: one webhook subscription/signing key
    # covers every store this deployment serves, same whether a given store
    # authenticates via OAuth or the ENV fallback above.
    def webhook_signature_key
      fetch(:webhook_signature_key, env_key: 'SQUARE_WEBHOOK_SIGNATURE_KEY')
    end

    def sandbox?
      environment == 'sandbox'
    end

    private

    def resolve_token
      return fetch(:access_token, env_key: 'SQUARE_ACCESS_TOKEN') unless @credential

      refresh_if_needed!
      @credential.access_token
    end

    def refresh_if_needed!
      return unless @credential.needs_refresh?

      response = SpreeSquare::OauthClient.refresh(@credential)
      @credential.update!(
        access_token: response.access_token,
        refresh_token: response.refresh_token,
        expires_at: Time.iso8601(response.expires_at),
        refresh_token_expires_at: response.refresh_token_expires_at.present? ? Time.iso8601(response.refresh_token_expires_at) : nil
      )
    rescue StandardError => e
      # A failed refresh shouldn't crash whatever sync job triggered this
      # client lookup — fall through and try the existing (possibly
      # still-valid, or about to 401) access_token rather than raising here.
      # The eventual 401 from Square is a clearer signal than this method
      # raising somewhere deep inside a webhook job.
      Rails.logger.error("[SpreeSquare] token refresh failed for store #{@credential.store_id}: #{e.message}")
    end

    def base_url
      sandbox? ? Square::Environment::SANDBOX : Square::Environment::PRODUCTION
    end

    def environment
      @credential&.square_environment || ENV.fetch('SQUARE_ENVIRONMENT', 'sandbox')
    end

    # Rails credentials first (config/credentials.yml.enc, scoped by
    # environment: production.yml.enc vs sandbox stays in the base file for
    # dev), falling back to plain ENV for 12-factor deployments (Heroku,
    # Render, Fly, and — today — our own .env-driven Docker Compose setup).
    def fetch(key, env_key:)
      Rails.application.credentials.dig(:square, environment.to_sym, key) || ENV[env_key].presence
    end
  end
end
