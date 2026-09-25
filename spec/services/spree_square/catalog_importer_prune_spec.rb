require 'json'

# 2.4.1 (OI-195): what is deleted in Square leaves Spree, guarded by a
# complete listing and a sanity cap. Real square.rb objects through the real
# SpreePos::CatalogSync; only the HTTP boundary (catalog.search) is stubbed.
RSpec.describe SpreeSquare::CatalogImporter, 'pruning' do
  let(:store) { Spree::Store.default }
  let!(:connection) do
    SpreePos::Connection.create!(store: store, provider: 'square', external_merchant_id: 'sq_merchant_1',
                                 catalog_role: 'source')
  end
  let(:catalog_api) { double('catalog api') }
  let(:client) { instance_double(SpreeSquare::Client, catalog: catalog_api) }
  let(:alerts) { [] }

  before do
    Spree::ShippingCategory.find_or_create_by!(name: 'Default')
    Spree::Channel.find_or_create_by!(code: 'online') { |c| c.name = 'Online Store'; c.store = store }
    allow(SpreeSquare::Client).to receive(:for_connection).with(connection).and_return(client)
    allow(SpreePos::Revalidator).to receive(:call)
    allow(SpreeSquare::Alerting).to receive(:capture) { |error, context:| alerts << [error, context] }
  end

  def obj(hash) = Square::Types::CatalogObject.coerce(JSON.parse(hash.to_json, symbolize_names: true))

  def category(id, name, version: 1) = { type: 'CATEGORY', id: id, version: version, category_data: { name: name } }

  def modifier_list(id, modifiers, version: 1, name: 'Sauce')
    { type: 'MODIFIER_LIST', id: id, version: version,
      modifier_list_data: { name: name, selection_type: 'SINGLE',
                            modifiers: modifiers.map do |mid, mname|
                              { type: 'MODIFIER', id: mid, version: version,
                                modifier_data: { name: mname, modifier_list_id: id,
                                                 price_money: { amount: 50, currency: 'USD' } } }
                            end } }
  end

  def item(id, version: 1, category: nil, lists: [], price: 1000)
    data = { name: "Dish #{id}", variations: [{ type: 'ITEM_VARIATION', id: "#{id}-V", version: version,
                                                item_variation_data: { item_id: id, name: 'Regular',
                                                                       pricing_type: 'FIXED_PRICING',
                                                                       price_money: { amount: price,
                                                                                      currency: 'USD' } } }] }
    data[:categories] = [{ id: category }] if category
    data[:modifier_list_info] = lists.map { |l| { modifier_list_id: l, enabled: true } } if lists.any?
    { type: 'ITEM', id: id, version: version, present_at_all_locations: true, item_data: data }
  end

  def response(objects, cursor: nil)
    Square::Types::SearchCatalogObjectsResponse.coerce({ objects: objects.map { |o| obj(o) }, related_objects: [],
                                                         cursor: cursor })
  end

  # A one-page listing (the common case).
  def listing(*objects)
    allow(catalog_api).to receive(:search).and_return(response(objects))
  end

  def import(**options) = described_class.call(connection: connection, **options)

  def dish(id) = Spree::Product.unscoped.find(SpreePos::ExternalRef.find_by(pos_connection: connection,
                                                                             resource_type: 'item',
                                                                             external_id: id).spree_id)

  let(:base_catalog) do
    [category('CAT_A', 'Pizzas'), category('CAT_B', 'Salads'),
     modifier_list('ML1', [%w[M1 Ranch], %w[M2 Blue]]),
     *%w[I1 I2 I3 I4 I5 I6 I7].map { |id| item(id, category: 'CAT_A', lists: ['ML1']) },
     item('S1', category: 'CAT_B')]
  end

  before do
    listing(*base_catalog)
    import
  end

  it 'discontinues an item deleted in Square, with its variation, and says how many' do
    listing(*base_catalog.reject { |o| o[:id] == 'I7' })

    result = import

    expect(dish('I7')).to be_discontinued
    expect(dish('I7').status).to eq('archived')
    expect(dish('I7').master.reload).to be_discontinued
    expect(dish('I1')).not_to be_discontinued
    expect(result.products_pruned).to eq(1)
    expect(result.variants_pruned).to eq(1)
    expect(result.removals_withheld).to eq(0)
    expect(alerts).to be_empty
  end

  it 'brings a deleted item back when Square lists it again, at the same version' do
    listing(*base_catalog.reject { |o| o[:id] == 'I7' })
    import
    listing(*base_catalog)

    import

    expect(dish('I7')).not_to be_discontinued
    expect(dish('I7').status).to eq('active')
  end

  it 'removes an option deleted from a modifier list, and every option of an emptied list' do
    list = SpreePos::ModifierList.find_by(pos_connection: connection, external_id: 'ML1')
    listing(*base_catalog.map { |o| o[:id] == 'ML1' ? modifier_list('ML1', [%w[M1 Ranch]], version: 2) : o })
    import
    expect(list.modifiers.reload.pluck(:external_id)).to eq(['M1'])

    listing(*base_catalog.map { |o| o[:id] == 'ML1' ? modifier_list('ML1', [], version: 3) : o })
    import
    expect(list.modifiers.reload).to be_empty
  end

  it 'deletes a category deleted in Square once its dish has left it' do
    listing(*base_catalog.reject { |o| o[:id] == 'CAT_B' }.map { |o| o[:id] == 'S1' ? item('S1', version: 2) : o })

    result = import

    expect(Spree::Taxon.where(name: 'Salads')).to be_empty
    expect(dish('S1').taxons).to be_empty
    expect(dish('S1')).not_to be_discontinued
    expect(result.categories_pruned).to eq(1)
  end

  describe 'the cap' do
    it 'withholds every removal when too much would go, still applies additions, and alerts' do
      shrunk = base_catalog.reject { |o| %w[I4 I5 I6 I7].include?(o[:id]) }
                           .map { |o| o[:id] == 'ML1' ? modifier_list('ML1', [%w[M1 Ranch]], version: 2) : o }
      listing(*shrunk, item('NEW1', category: 'CAT_A'))

      result = import

      expect(%w[I4 I5 I6 I7].map { |id| dish(id) }).to all(satisfy { |p| !p.discontinued? })
      expect(SpreePos::Modifier.where(pos_connection_id: connection.id).pluck(:external_id)).to include('M2')
      expect(dish('NEW1')).to be_present
      expect(result.removals_withheld).to eq(1)
      expect(result.products_pruned).to eq(0)
      expect(result.warnings).to include(a_string_matching(/would remove more than 25% of: products/))
      expect(alerts.size).to eq(1)
      expect(alerts.first.first).to be_a(described_class::PruneCapExceeded)
      expect(alerts.first.last).to include(area: 'catalog_prune_cap', connection_id: connection.id)
      expect(alerts.first.last[:removals]).to include(products: 4, modifiers: 1)
    end

    it 'treats an empty listing as suspect: nothing is removed and it alerts' do
      listing

      result = import

      expect(dish('I1')).not_to be_discontinued
      expect(result.removals_withheld).to eq(1)
      expect(alerts.size).to eq(1)
    end

    it 'lets a small menu lose a couple of dishes' do
      listing(*base_catalog.reject { |o| %w[I6 I7].include?(o[:id]) })

      expect(import.products_pruned).to eq(2)
      expect(alerts).to be_empty
    end

    it 'can be raised for one run by an operator who confirmed the change in Square' do
      listing(*base_catalog.reject { |o| %w[I4 I5 I6 I7].include?(o[:id]) })

      result = import(max_prune_fraction: 1.0)

      expect(result.products_pruned).to eq(4)
      expect(result.removals_withheld).to eq(0)
    end

    it 'refuses the whole import when the installed spree_pos cannot withhold removals' do
      sync = SpreePos::CatalogSync.new(connection: connection)
      sync.singleton_class.send(:undef_method, :removals_enabled=)
      allow(SpreePos::CatalogSync).to receive(:new).and_return(sync)
      listing(*base_catalog.reject { |o| %w[I4 I5 I6 I7].include?(o[:id]) }, item('NEW1'))

      expect { import }.to raise_error(described_class::PruneCapExceeded)
      expect(SpreePos::ExternalRef.where(pos_connection: connection, external_id: 'NEW1')).to be_empty
      expect(dish('I4')).not_to be_discontinued
    end
  end

  # 2.4.2: the provider contract's entry point stays the one seam, so a host
  # that stubs or overrides it still controls what is imported.
  it 'reads the catalog through CatalogAdapter#fetch_all' do
    empty = SpreePos::Catalog::Snapshot.new(categories: [], modifier_groups: [], taxes: [], items: [])
    allow_any_instance_of(SpreeSquare::CatalogAdapter).to receive(:fetch_all).and_return(empty)

    result = import

    expect(catalog_api).to have_received(:search).once # the setup import only
    expect(result.items_count).to eq(0)
    expect(result.removals_withheld).to eq(1)
  end

  describe 'an incomplete listing' do
    it 'prunes and maps nothing when a later page fails' do
      allow(catalog_api).to receive(:search).with(hash_including(cursor: nil))
                                            .and_return(response(base_catalog.first(3), cursor: 'p2'))
      allow(catalog_api).to receive(:search).with(hash_including(cursor: 'p2')).and_raise(StandardError, 'HTTP 500')

      expect { import }.to raise_error(StandardError, 'HTTP 500')
      expect(%w[I1 I7 S1].map { |id| dish(id) }).to all(satisfy { |p| !p.discontinued? })
    end

    it 'refuses a cursor that repeats' do
      allow(catalog_api).to receive(:search).and_return(response(base_catalog.first(3), cursor: 'loop'))

      expect { import }.to raise_error(SpreeSquare::CatalogAdapter::IncompleteListing, /twice/)
      expect(dish('I7')).not_to be_discontinued
    end

    it 'counts an item missed by one pass of a paged listing as present' do
      first_page = base_catalog.first(3)
      rest = base_catalog.drop(3)
      allow(catalog_api).to receive(:search).with(hash_including(include_related_objects: true, cursor: nil))
                                            .and_return(response(first_page, cursor: 'p2'))
      allow(catalog_api).to receive(:search).with(hash_including(include_related_objects: true, cursor: 'p2'))
                                            .and_return(response(rest.reject { |o| o[:id] == 'I7' }))
      allow(catalog_api).to receive(:search).with(hash_including(include_related_objects: false, cursor: nil))
                                            .and_return(response(first_page, cursor: 'q2'))
      allow(catalog_api).to receive(:search).with(hash_including(include_related_objects: false, cursor: 'q2'))
                                            .and_return(response(rest))

      result = import

      expect(dish('I7')).not_to be_discontinued
      expect(result.products_pruned).to eq(0)
    end
  end
end
