module SpreeSquare
  # Deprecating shim (plan step 18) — see catalog_webhook_job.rb's comment.
  class InventoryWebhookJob < BaseJob
    def perform(webhook_event_id) = SpreePos::InventoryWebhookJob.perform_now(webhook_event_id)
  end
end
