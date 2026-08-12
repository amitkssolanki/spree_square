module SpreeSquare
  # Handles `inventory.count.updated`. Unlike the catalog webhook, this
  # payload is fully actionable on its own — catalog_object_id, location_id,
  # and the new quantity all arrive inline, no follow-up API call needed.
  class InventoryWebhookJob < BaseJob
    retry_on StandardError, wait: :polynomially_longer, attempts: 5 do |job, error|
      SpreeSquare::WebhookEvent.find_by(id: job.arguments.first)&.mark_failed!(error)
      SpreeSquare::Alerting.capture(error, context: 'inventory_webhook')
    end

    def perform(webhook_event_id)
      event = SpreeSquare::WebhookEvent.find(webhook_event_id)

      counts = event.payload.dig('data', 'object', 'inventory_counts') || []
      counts.each do |count|
        SpreeSquare::InventorySync.call(
          catalog_object_id: count['catalog_object_id'],
          location_id: count['location_id'],
          quantity: count['quantity'],
          state: count['state']
        )
      end

      event.mark_processed!
    end
  end
end
