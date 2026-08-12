module SpreeSquare
  # Handles `catalog.version.updated`. Square's payload is deliberately
  # coarse — it says the catalog changed, not what changed — so the handler
  # just re-runs a full import. Fine for a restaurant-sized catalog; would
  # need to become a scoped/incremental fetch for a larger one.
  class CatalogWebhookJob < BaseJob
    # A block passed to retry_on runs only once retries are exhausted —
    # normal transient failures retry silently; only a truly stuck job
    # reaches here and gets flagged.
    retry_on StandardError, wait: :polynomially_longer, attempts: 5 do |job, error|
      SpreeSquare::WebhookEvent.find_by(id: job.arguments.first)&.mark_failed!(error)
      SpreeSquare::Alerting.capture(error, context: 'catalog_webhook')
    end

    def perform(webhook_event_id)
      SpreeSquare::CatalogImporter.call
      SpreeSquare::WebhookEvent.find(webhook_event_id).mark_processed!
    end
  end
end
