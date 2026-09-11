require 'rake'
require 'stringio'

# The command-level accidental-trigger guard. The B2 mutation must be
# impossible to run by typing the task name alone, and impossible to run
# against a plan nobody reviewed.
RSpec.describe 'spree_square:b2 rake tasks' do
  let(:store) { Spree::Store.default }
  let!(:connection) do
    create(:pos_connection, store: store, provider: 'square', catalog_role: 'source', external_merchant_id: 'MERCHANT_RAKE')
  end

  GUARD_ENV = %w[B2_CONFIRM_PLAN ALLOW_UNRESOLVED POS_CONNECTION_ID].freeze

  before(:all) do
    @previous_rake = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load File.expand_path('../../../lib/tasks/spree_square_b2.rake', __dir__)
  end

  after(:all) { Rake.application = @previous_rake }

  around do |example|
    saved = ENV.to_h.slice(*GUARD_ENV)
    GUARD_ENV.each { |k| ENV.delete(k) }
    example.run
  ensure
    GUARD_ENV.each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
  end

  def legacy_item(external_id)
    product = create(:product, stores: [store], name: "Rake Dish #{external_id}")
    SpreeSquare::CatalogMapping.create!(square_catalog_object_id: external_id,
                                        square_object_type: SpreeSquare::CatalogMapping::ITEM,
                                        product: product, square_version: 1)
  end

  def capture_io
    out = StringIO.new
    err = StringIO.new
    orig_out = $stdout
    orig_err = $stderr
    $stdout = out
    $stderr = err
    yield
  ensure
    $stdout = orig_out
    $stderr = orig_err
    @out = out.string
    @err = err.string
  end

  def run(task) = Rake::Task["spree_square:b2:#{task}"].execute

  it 'refuses to mutate when B2_CONFIRM_PLAN is absent, and writes nothing' do
    legacy_item('sq_rake_1')

    expect { capture_io { run(:migrate) } }.to raise_error(SystemExit)
    expect(@err).to include('B2_CONFIRM_PLAN')
    expect(@err).to include('Nothing was written')
    expect(SpreePos::ExternalRef.count).to eq(0)
  end

  it 'refuses a digest that does not match the current data, and writes nothing' do
    legacy_item('sq_rake_1')
    ENV['B2_CONFIRM_PLAN'] = 'deadbeefdeadbeef'

    expect { capture_io { run(:migrate) } }
      .to raise_error(SpreeSquare::LegacyCatalogReconciliation::Migrator::InvariantViolation, /plan digest mismatch/)
    expect(SpreePos::ExternalRef.count).to eq(0)
  end

  it 'prints the plan digest from the dry run, for the operator to confirm' do
    legacy_item('sq_rake_1')

    capture_io { run(:dry_run) }

    expect(@out).to include("Plan digest: #{SpreeSquare::LegacyCatalogReconciliation.analyze.plan_digest}")
  end

  it 'mutates when confirmed with the digest the dry run printed' do
    legacy_item('sq_rake_1')
    ENV['B2_CONFIRM_PLAN'] = SpreeSquare::LegacyCatalogReconciliation.analyze.plan_digest

    expect { capture_io { run(:migrate) } }.to change(SpreePos::ExternalRef, :count).by(1)
  end
end
