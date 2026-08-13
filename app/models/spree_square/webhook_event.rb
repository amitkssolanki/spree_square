module SpreeSquare
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
