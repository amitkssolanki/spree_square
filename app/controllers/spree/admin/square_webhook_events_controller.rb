module Spree
  module Admin
    # Read-only support/diagnostic view of every inbound Square webhook —
    # what arrived, whether it processed, and the error if it didn't.
    class SquareWebhookEventsController < ResourceController
      def model_class
        SpreeSquare::WebhookEvent
      end
    end
  end
end
