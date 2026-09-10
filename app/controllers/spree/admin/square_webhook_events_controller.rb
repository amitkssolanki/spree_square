module Spree
  module Admin
    # Read-only support/diagnostic view of every inbound Square webhook —
    # what arrived, whether it processed, and the error if it didn't.
    #
    # Repointed at SpreePos::WebhookEvent (Agent D2's provider-neutral
    # webhook log, table spree_pos_webhook_events) — same route/URL.
    class SquareWebhookEventsController < ResourceController
      def model_class
        SpreePos::WebhookEvent
      end
    end
  end
end
