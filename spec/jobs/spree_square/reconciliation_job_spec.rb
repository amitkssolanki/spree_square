# The real behavior now lives in SpreePos::ReconciliationJob
# (spree_pos/spec/jobs/spree_pos/reconciliation_job_spec.rb). This is a
# deprecating shim (plan step 18) — see catalog_webhook_job_spec.rb.
RSpec.describe SpreeSquare::ReconciliationJob do
  it 'delegates synchronously to SpreePos::ReconciliationJob' do
    expect(SpreePos::ReconciliationJob).to receive(:perform_now)

    described_class.perform_now
  end
end
