module SpreeSquare
  # Deprecating shim (plan step 18) — see catalog_webhook_job.rb's comment.
  class OrderWebhookJob < BaseJob
    def perform(webhook_event_id) = SpreePos::OrderWebhookJob.perform_now(webhook_event_id)
  end
end
