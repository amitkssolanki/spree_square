module SpreeSquare
  # Everything Square-specific about inbound webhooks: signature
  # verification, payload shape, and the plan-15.4 event-to-kind mapping.
  # Moved here from webhook_verifier.rb (plan section 24: "webhook_verifier.rb
  # -> webhook_adapter.rb") and from OrderWebhookJob's private payload-digging
  # methods (plan section 25 step 17) so that neither
  # SpreePos::WebhooksController nor (once Agent D3 rewires it per the
  # report handoff) SpreeSquare::OrderWebhookJob need to know Square's wire
  # format.
  class WebhookAdapter
    SIGNATURE_HEADER = 'x-square-hmacsha256-signature'.freeze

    EVENT_KIND_MAP = {
      'catalog.version.updated' => 'catalog_changed',
      'inventory.count.updated' => 'inventory_changed',
      'order.updated' => 'order_changed',
      'order.fulfillment.updated' => 'order_changed'
    }.freeze

    class << self
      # Verifies the `x-square-hmacsha256-signature` header Square sends on
      # every webhook POST. Algorithm per Square's spec (mirrored from the
      # legacy SDK's WebhooksHelper, since the current SDK doesn't ship a
      # verifier — Square's signing scheme itself, not the SDK's shape, is
      # what this depends on), unchanged from the old WebhookVerifier.valid?:
      #
      #   base64(HMAC-SHA256(signing_key, notification_url + raw_request_body))
      #
      # compared against the header using a constant-time comparison.
      def verify(url:, body:, signature:, signing_key:)
        return false if body.nil? || signature.blank? || signing_key.blank?

        payload = "#{url}#{body}".dup.force_encoding('UTF-8')
        digest = OpenSSL::HMAC.digest('sha256', signing_key.dup.force_encoding('UTF-8'), payload)
        expected = Base64.strict_encode64(digest)

        ActiveSupport::SecurityUtils.secure_compare(expected, signature)
      end

      # The header Square signs every webhook POST with.
      def signature_header
        SIGNATURE_HEADER
      end

      # Where the signing key comes from today: the one Client instance's
      # webhook subscription key (plan 15.2's app-level default — "if every
      # merchant in the deployment is served by one application-level
      # subscription... one key verifies all of them"). Per-connection
      # override (`connection.webhook_secret`) isn't consulted yet because
      # no real SpreePos::Connection rows exist for Square in this
      # codebase — the same "onboarding is Phase 5" constraint Agent D1
      # hit for order push.
      def signing_key
        SpreeSquare::Client.webhook_signature_key
      end

      # Square's `event_id` is already a real idempotency key (plan 15.1).
      def idempotency_key_for(payload)
        payload['event_id']
      end

      # Square timestamps every event with an RFC 3339 `created_at`. Parse
      # failures return nil rather than raising: `occurred_at` is
      # observability metadata, and losing it must never cost us the event
      # itself.
      def parse_time(value)
        return nil if value.blank?

        Time.zone.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      # Maps Square's raw `type` string to SpreePos::WebhookEvent's closed
      # `kind` vocabulary (plan 15.4's event-to-action table).
      def kind_for(event_type)
        EVENT_KIND_MAP.fetch(event_type, 'unknown')
      end

      # The provider-neutral webhook contract: zero or more
      # SpreePos::Webhooks::Event values per delivery. No persistence, no
      # side effects.
      #
      # Square always sends exactly ONE event per POST, so this always
      # returns a one-element array. The array shape is not Square's
      # concern -- it exists because the contract has to serve a provider
      # that batches several merchants into one delivery, and a uniform
      # shape is what keeps SpreePos::WebhooksController free of any
      # per-provider branch.
      #
      # `raw:` is the whole payload here, for the same reason: with one
      # event per delivery, the event's own slice IS the delivery, and
      # SpreePos::OrderWebhookJob goes on handing that payload straight
      # back to `extract_order_status` exactly as before.
      def extract_events(payload)
        [
          SpreePos::Webhooks::Event.new(
            idempotency_key: idempotency_key_for(payload),
            external_merchant_id: payload['merchant_id'],
            # Square's location, when the event names one. Left nil rather
            # than guessed: an event routed to the wrong restaurant is the
            # single easiest way to break a franchise.
            external_location_id: payload.dig('data', 'object', 'location_id'),
            kind: kind_for(payload['type']),
            event_type: payload['type'],
            resource_ref: payload.dig('data', 'id'),
            occurred_at: parse_time(payload['created_at']),
            raw: payload
          )
        ]
      end

      # For SpreeSquare::OrderWebhookJob to call once Agent D3 rewires it
      # (see this batch's report — the job currently reads
      # SpreeSquare::WebhookEvent directly and digs into the payload
      # itself; both need to change to SpreePos::WebhookEvent /
      # this method). Turns a recorded order/fulfillment webhook payload
      # into the kwargs SpreePos::OrderStatusMapper.call expects. Payload
      # shapes verified against real Square test webhooks (not assumed
      # from docs), carried over verbatim from OrderWebhookJob's old
      # handle_order_updated/handle_fulfillment_updated:
      #
      #   order.updated:             data.object.order_updated
      #                              { order_id, state, version, ... }
      #   order.fulfillment.updated: data.object.order_fulfillment_updated
      #                              { order_id, version, fulfillment_update:
      #                                [{ fulfillment_uid, new_state, old_state }] }
      #
      # Always returns an Array: order.fulfillment.updated can report more
      # than one fulfillment change per delivery, each needing its own
      # OrderStatusMapper.call. `order.updated` always returns a
      # single-element array. Any other event_type returns [].
      #
      # Usage (Agent D3, in OrderWebhookJob#perform):
      #
      #   SpreeSquare::WebhookAdapter.extract_order_status(event.payload, event.event_type).each do |status|
      #     SpreePos::OrderStatusMapper.call(**status)
      #   end
      #
      # Each Hash carries exactly the kwargs
      # SpreePos::OrderStatusMapper.call(external_order_id:, version:,
      # order_state: nil, fulfillment_state: nil) expects (this batch's
      # assumed call shape — see report; square_order_id: renamed to
      # external_order_id:, everything else unchanged from today's
      # SpreeSquare::OrderStatusMapper.call).
      def extract_order_status(payload, event_type)
        case event_type
        when 'order.updated'
          data = payload.dig('data', 'object', 'order_updated') || {}
          [{
            external_order_id: data['order_id'],
            version: data['version'],
            order_state: data['state'],
            fulfillment_state: nil
          }]
        when 'order.fulfillment.updated'
          data = payload.dig('data', 'object', 'order_fulfillment_updated') || {}
          Array(data['fulfillment_update']).map do |update|
            {
              external_order_id: data['order_id'],
              version: data['version'],
              order_state: nil,
              fulfillment_state: update['new_state']
            }
          end
        else
          []
        end
      end
    end
  end
end
