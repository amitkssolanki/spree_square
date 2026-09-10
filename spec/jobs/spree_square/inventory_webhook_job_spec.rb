# The real behavior now lives in SpreePos::InventoryWebhookJob
# (spree_pos/spec/jobs/spree_pos/inventory_webhook_job_spec.rb). This is a
# deprecating shim (plan step 18) — see catalog_webhook_job_spec.rb.
RSpec.describe SpreeSquare::InventoryWebhookJob do
  it 'delegates synchronously to SpreePos::InventoryWebhookJob with the same webhook_event_id' do
    expect(SpreePos::InventoryWebhookJob).to receive(:perform_now).with(42)

    described_class.perform_now(42)
  end
end
