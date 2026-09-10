# The real behavior now lives in SpreePos::OrderWebhookJob
# (spree_pos/spec/jobs/spree_pos/order_webhook_job_spec.rb). This is a
# deprecating shim (plan step 18) — see catalog_webhook_job_spec.rb.
RSpec.describe SpreeSquare::OrderWebhookJob do
  it 'delegates synchronously to SpreePos::OrderWebhookJob with the same webhook_event_id' do
    expect(SpreePos::OrderWebhookJob).to receive(:perform_now).with(42)

    described_class.perform_now(42)
  end
end
