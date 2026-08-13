module SpreeSquare
  # Receives Square webhook notifications. Square-signature-verified instead
  # of Spree/Devise-authenticated, and deliberately does the least possible
  # work synchronously: verify, record, ack, hand off to a job. Square treats
  # a slow or non-2xx response as a delivery failure and retries.
  class WebhooksController < ActionController::Base
    # Explicit, not just `skip_before_action :verify_authenticity_token` —
    # this controller doesn't inherit the host app's ApplicationController
    # (which is where `protect_from_forgery` normally gets declared), so
    # Brakeman's ForgerySetting check correctly flags it as never actually
    # configured either way. `:null_session` degrades a forged/missing
    # token to an empty session instead of raising — appropriate here since
    # this endpoint is Square-signature-verified, not session-authenticated,
    # so there's no session to protect in the first place.
    protect_from_forgery with: :null_session

    def create
      raw_body = request.raw_post
      signature = request.headers['x-square-hmacsha256-signature']

      unless SpreeSquare::WebhookVerifier.valid?(
        url: request.original_url,
        body: raw_body,
        signature: signature,
        signing_key: SpreeSquare::Client.instance.webhook_signature_key
      )
        Rails.logger.warn('[SpreeSquare] webhook signature verification failed')
        return head :unauthorized
      end

      payload = JSON.parse(raw_body)
      event = find_or_log_event(payload)
      enqueue_job(event) if event.previously_new_record?

      head :ok
    rescue JSON::ParserError
      head :bad_request
    end

    private

    def find_or_log_event(payload)
      SpreeSquare::WebhookEvent.find_or_create_by!(square_event_id: payload['event_id']) do |event|
        event.event_type = payload['type']
        event.payload = payload
      end
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      # Lost a race with a concurrent duplicate delivery — the row exists now
      # either way, and it's already being (or has been) processed once.
      SpreeSquare::WebhookEvent.find_by!(square_event_id: payload['event_id'])
    end

    def enqueue_job(event)
      case event.event_type
      when 'catalog.version.updated'
        SpreeSquare::CatalogWebhookJob.perform_later(event.id)
      when 'inventory.count.updated'
        SpreeSquare::InventoryWebhookJob.perform_later(event.id)
      when 'order.updated', 'order.fulfillment.updated'
        SpreeSquare::OrderWebhookJob.perform_later(event.id)
      end
    end
  end
end
