module SpreeSquare
  # DEPRECATED as of plan sequence step 17 (webhooks controller +
  # SpreeSquare::WebhookAdapter): SpreeSquare::WebhooksController and
  # SpreePos::WebhooksController both now write to SpreePos::WebhookEvent
  # (table spree_pos_webhook_events) instead. This class and its table are
  # left in place, untouched, on purpose — deleting it breaks Rails boot,
  # because config/initializers/spree_admin_square_tables.rb and
  # spree_admin_square_navigation.rb still reference the bare
  # SpreeSquare::WebhookEvent constant in an `after_initialize` block
  # (verified empirically: removing this file raises
  # "uninitialized constant SpreeSquare::WebhookEvent" the moment the app
  # boots, not just when webhook code runs), and
  # app/jobs/spree_square/{catalog,inventory,order}_webhook_job.rb still
  # read/write it too. All of those are the admin/jobs worker's scope
  # (Agent D3, plan sequence step 18) to repoint at SpreePos::WebhookEvent
  # (idempotency_key instead of square_event_id; event_type/status/
  # processed_at/error_message/created_at are unchanged names) — once that
  # lands, this model, its migration, and the now-orphaned
  # spree_square_webhook_events table can be deleted. No new events are
  # written here going forward; existing rows are transient operational
  # data, not something that needs migrating (see this batch's report).
  #
  # Idempotency + audit log for inbound Square webhook notifications. The
  # unique index on square_event_id is what makes Square's at-least-once
  # delivery safe to process without duplicating side effects.
  class WebhookEvent < Spree.base_class
    self.table_name = 'spree_square_webhook_events'

    # Ruby-level, not a DB-level `default: {}` on the migration — MySQL
    # rejects a literal DEFAULT on a JSON column outright (see that
    # migration's own comment). This works identically on every adapter.
    attribute :payload, default: -> { {} }

    validates :square_event_id, presence: true, uniqueness: true
    validates :event_type, presence: true

    scope :pending, -> { where(status: 'pending') }

    def mark_processed!
      update!(status: 'processed', processed_at: Time.current)
    end

    def mark_failed!(error)
      update!(status: 'failed', processed_at: Time.current, error_message: error.to_s.truncate(1000))
    end
  end
end
