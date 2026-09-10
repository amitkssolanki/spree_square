module SpreeSquare
  # Thin delegating wrapper -- the real, provider-neutral implementation
  # moved to SpreePos::Alerting (Phase 2D, step 16b; see that class's own
  # comment). Kept here, rather than deleted, so the four job files not in
  # this batch's scope (order_webhook_job.rb, catalog_webhook_job.rb,
  # inventory_webhook_job.rb, reconciliation_job.rb) keep calling
  # `SpreeSquare::Alerting.capture` unchanged.
  class Alerting
    def self.capture(error, context: {})
      SpreePos::Alerting.capture(error, context: context, source: 'spree_square')
    end
  end
end
