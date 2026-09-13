require File.join(SpreeSquare::Engine.root, 'db/migrate/20260913000002_keep_existing_square_locations_pushing_orders')

# spree_pos 0.4.0's order-push switch defaults every location to disabled.
# This migration is what keeps a live Square kitchen receiving tickets across
# that deploy, so it is covered like code: exactly which rows it enables.
RSpec.describe KeepExistingSquareLocationsPushingOrders do
  subject(:migration) { described_class.new }

  let(:store) { Spree::Store.default.presence || create(:store) }

  around do |example|
    original = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
    example.run
    ActiveRecord::Migration.verbose = original
  end

  def location_for(provider)
    connection = SpreePos::Connection.create!(store: store, provider: provider, external_merchant_id: "#{provider}_m",
                                              catalog_role: 'none', status: 'active')
    SpreePos::Location.create!(pos_connection: connection, stock_location: create(:stock_location, store: store),
                               external_location_id: "#{provider}_loc")
  end

  it 'enables order pushing on an existing Square location and records why' do
    location = location_for('square')

    migration.up

    expect(location.reload).to have_attributes(
      order_push_enabled: true, order_push_changed_by: 'migration:keep_existing_square_locations_pushing_orders'
    )
  end

  it 'never enables another provider, including Clover' do
    clover = location_for('clover')
    other = location_for('toast')

    migration.up

    expect(clover.reload.order_push_enabled).to be(false)
    expect(other.reload.order_push_enabled).to be(false)
  end

  it 'does not rewrite the audit trail of a Square location that is already enabled' do
    location = location_for('square')
    SpreePos::OrderPushActivation.new(location, 'operator@example.com').send(:change, true)

    migration.up

    expect(location.reload.order_push_changed_by).to eq('operator@example.com')
  end

  it 'fails loudly when spree_pos 0.4.0 has not added the column' do
    allow(migration).to receive(:column_exists?).and_call_original
    allow(migration).to receive(:column_exists?).with(:spree_pos_locations, :order_push_enabled).and_return(false)

    expect { migration.up }.to raise_error(/order_push_enabled is missing/)
  end
end
