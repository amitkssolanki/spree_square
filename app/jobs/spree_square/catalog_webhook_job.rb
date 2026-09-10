module SpreeSquare
  # Deprecating shim (plan step 18): the real job moved to
  # SpreePos::CatalogWebhookJob (same argument, same behavior). Kept so any
  # code still enqueuing `SpreeSquare::CatalogWebhookJob` by name — today,
  # that's spree_square/app/controllers/spree_square/webhooks_controller.rb,
  # which Agent D2 owns updating — keeps working unchanged.
  class CatalogWebhookJob < BaseJob
    def perform(webhook_event_id) = SpreePos::CatalogWebhookJob.perform_now(webhook_event_id)
  end
end
