# The real behavior now lives in SpreePos::CatalogWebhookJob
# (spree_pos/spec/jobs/spree_pos/catalog_webhook_job_spec.rb). This is a
# deprecating shim (plan step 18) — its only job is to delegate with the
# same argument, for anything still enqueuing the old class name (today:
# spree_square/app/controllers/spree_square/webhooks_controller.rb).
RSpec.describe SpreeSquare::CatalogWebhookJob do
  it 'delegates synchronously to SpreePos::CatalogWebhookJob with the same webhook_event_id' do
    expect(SpreePos::CatalogWebhookJob).to receive(:perform_now).with(42)

    described_class.perform_now(42)
  end
end
