module SpreeSquare
  # Handles `order.updated` and `order.fulfillment.updated`. Payload shapes
  # verified against real Square test webhooks (not assumed from docs):
  #
  #   order.updated:            data.object.order_updated
  #                              { order_id, state, version, ... }
  #   order.fulfillment.updated: data.object.order_fulfillment_updated
  #                              { order_id, version, fulfillment_update:
  #                                [{ fulfillment_uid, new_state, old_state }] }
  class OrderWebhookJob < BaseJob
    retry_on StandardError, wait: :polynomially_longer, attempts: 5 do |job, error|
      SpreeSquare::WebhookEvent.find_by(id: job.arguments.first)&.mark_failed!(error)
      SpreeSquare::Alerting.capture(error, context: 'order_webhook')
    end

    def perform(webhook_event_id)
      event = SpreeSquare::WebhookEvent.find(webhook_event_id)

      case event.event_type
      when 'order.updated'
        handle_order_updated(event.payload)
      when 'order.fulfillment.updated'
        handle_fulfillment_updated(event.payload)
      end

      event.mark_processed!
    end

    private

    def handle_order_updated(payload)
      data = payload.dig('data', 'object', 'order_updated') || {}
      SpreeSquare::OrderStatusMapper.call(
        square_order_id: data['order_id'],
        version: data['version'],
        order_state: data['state']
      )
    end

    def handle_fulfillment_updated(payload)
      data = payload.dig('data', 'object', 'order_fulfillment_updated') || {}
      Array(data['fulfillment_update']).each do |update|
        SpreeSquare::OrderStatusMapper.call(
          square_order_id: data['order_id'],
          version: data['version'],
          fulfillment_state: update['new_state']
        )
      end
    end
  end
end
