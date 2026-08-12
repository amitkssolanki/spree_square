module Spree
  module Admin
    # Self-service "Connect to Square" flow for the current store — the
    # OAuth replacement for hand-generating SQUARE_ACCESS_TOKEN in .env.
    # Square requires multi-merchant apps to use OAuth rather than personal
    # access tokens (a prerequisite for App Marketplace listing), and this is
    # the admin-facing half of that: authorize -> callback -> store an
    # encrypted SpreeSquare::Credential -> SpreeSquare::Client picks it up
    # automatically from here on (see Client.for_store).
    class SquareOauthController < Spree::Admin::BaseController
      before_action :ensure_oauth_configured, only: %i[connect callback]

      def show
        @credential = SpreeSquare::Credential.find_by(store: current_store)
      end

      # Kicks off the OAuth authorization-code flow: redirect the admin's
      # browser to Square's own consent page. `state` is a CSRF token,
      # verified on the way back in #callback — without it, an attacker
      # could trick an admin into connecting *the attacker's* Square account
      # to this store by crafting their own callback link.
      def connect
        state = SecureRandom.hex(24)
        session[:square_oauth_state] = state

        redirect_to SpreeSquare::OauthClient.authorize_url(
          redirect_uri: admin_callback_square_oauth_url,
          state: state
        ), allow_other_host: true
      end

      def callback
        expected_state = session.delete(:square_oauth_state)

        if params[:error].present?
          flash[:error] = Spree.t(:square_oauth_denied, default: "Square authorization was cancelled: #{params[:error_description] || params[:error]}")
          return redirect_to admin_square_oauth_path
        end

        if expected_state.blank? || !ActiveSupport::SecurityUtils.secure_compare(expected_state, params[:state].to_s)
          flash[:error] = Spree.t(:square_oauth_state_mismatch, default: 'Square authorization could not be verified (invalid state) — please try connecting again.')
          return redirect_to admin_square_oauth_path
        end

        response = SpreeSquare::OauthClient.exchange_code(code: params[:code], redirect_uri: admin_callback_square_oauth_url)
        save_credential!(response)

        flash[:success] = Spree.t(:square_oauth_connected, default: 'Connected to Square.')
        redirect_to admin_square_oauth_path
      rescue Square::Errors::ResponseError => e
        Rails.logger.error("[SpreeSquare] OAuth token exchange failed: #{e.message}")
        flash[:error] = Spree.t(:square_oauth_exchange_failed, default: 'Could not connect to Square — please try again.')
        redirect_to admin_square_oauth_path
      end

      def destroy
        credential = SpreeSquare::Credential.find_by(store: current_store)
        if credential
          begin
            SpreeSquare::OauthClient.revoke(credential)
          rescue StandardError => e
            # A failed remote revoke (token already invalid, network blip)
            # shouldn't trap the admin into a "disconnect" button that never
            # works — the local side is what actually stops this store's
            # syncing, so proceed to destroy the row regardless.
            Rails.logger.warn("[SpreeSquare] OAuth revoke failed, disconnecting locally anyway: #{e.message}")
          end
          credential.destroy!
        end

        flash[:success] = Spree.t(:square_oauth_disconnected, default: 'Disconnected from Square.')
        redirect_to admin_square_oauth_path
      end

      private

      def ensure_oauth_configured
        return if ENV['SQUARE_APPLICATION_SECRET'].present?

        flash[:error] = 'SQUARE_APPLICATION_SECRET is not set — add it to .env first (see spree_square/README.md).'
        redirect_to admin_square_oauth_path
      end

      def save_credential!(oauth_response)
        credential = SpreeSquare::Credential.find_or_initialize_by(store: current_store)
        credential.assign_attributes(
          square_merchant_id: oauth_response.merchant_id,
          square_environment: ENV.fetch('SQUARE_ENVIRONMENT', 'sandbox'),
          access_token: oauth_response.access_token,
          refresh_token: oauth_response.refresh_token,
          expires_at: parse_time(oauth_response.expires_at),
          refresh_token_expires_at: parse_time(oauth_response.refresh_token_expires_at),
          scopes: SpreeSquare::OauthClient::SCOPES
        )
        credential.save!
      end

      def parse_time(value)
        value.present? ? Time.iso8601(value) : nil
      end
    end
  end
end
