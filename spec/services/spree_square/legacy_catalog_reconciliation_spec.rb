# B2: the cutover from this gem's legacy mapping tables to
# SpreePos::ExternalRef. Every classification the brief requires gets its
# own example here; the four-step production-shaped cycle (dry run ->
# mutation -> dry run -> mutation) lives in its own spec file next door.
RSpec.describe SpreeSquare::LegacyCatalogReconciliation do
  let(:store) { Spree::Store.default }
  let!(:connection) do
    create(:pos_connection, store: store, provider: 'square', catalog_role: 'source',
                            external_merchant_id: 'MERCHANT_MAIN')
  end

  def legacy_item(external_id, product, version: 1)
    SpreeSquare::CatalogMapping.create!(square_catalog_object_id: external_id,
                                        square_object_type: SpreeSquare::CatalogMapping::ITEM,
                                        product: product, square_version: version)
  end

  def legacy_variation(external_id, variant, version: 1)
    SpreeSquare::CatalogMapping.create!(square_catalog_object_id: external_id,
                                        square_object_type: SpreeSquare::CatalogMapping::ITEM_VARIATION,
                                        variant: variant, square_version: version)
  end

  def legacy_category(external_id, taxon, version: 1)
    SpreeSquare::TaxonMapping.create!(square_category_id: external_id, taxon: taxon, square_version: version)
  end

  def category(name)
    Spree::Category.create!(name: name, store: store)
  end

  def product(name = 'Margherita')
    create(:product, stores: [store], name: name)
  end

  def classification_of(report, external_id)
    report.findings.find { |f| f.external_id == external_id }&.classification
  end

  describe 'the dry run' do
    it 'performs zero writes' do
      legacy_item('sq_item_1', product)
      legacy_category('sq_cat_1', category('Pizza'))

      expect { described_class.analyze }.not_to change(SpreePos::ExternalRef, :count).from(0)
    end

    it 'never touches the legacy rows it reads' do
      mapping = legacy_item('sq_item_1', product)

      expect { described_class.analyze }.not_to(change { mapping.reload.attributes })
      expect(SpreeSquare::CatalogMapping.count).to eq(1)
    end

    it 'is deterministic: the same data reports the same counts and the same row order' do
      3.times { |i| legacy_item("sq_item_#{i}", product("Item #{i}")) }
      legacy_category('sq_cat_1', category('Pizza'))

      first = described_class.analyze
      second = described_class.analyze

      expect(second.counts).to eq(first.counts)
      expect(second.findings.map(&:sort_key)).to eq(first.findings.map(&:sort_key))
    end

    it 'reports every field an operator needs to resolve a row without opening the database' do
      spree_product = product
      mapping = legacy_item('sq_item_1', spree_product, version: 7)

      finding = described_class.analyze.findings.first

      expect(finding.to_h).to include(
        resource_type: 'item',
        external_id: 'sq_item_1',
        spree_type: 'Spree::Product',
        spree_id: spree_product.id,
        external_version: 7,
        legacy_table: 'spree_square_catalog_mappings',
        legacy_id: mapping.id,
        pos_connection_id: connection.id,
        pos_connection_merchant_id: 'MERCHANT_MAIN',
        store_id: store.id
      )
    end
  end

  describe 'item mappings' do
    it 'classifies an ordinary item mapping as convertible' do
      legacy_item('sq_item_1', product)

      expect(classification_of(described_class.analyze, 'sq_item_1')).to eq(:convertible)
    end

    # The deleted-and-recreated signature: Square issues a NEW catalog
    # object id for the recreated object, so two legacy rows end up
    # pointing at the same Spree product. ExternalRef's partial unique
    # index allows only one.
    it 'surfaces a deleted/recreated collision and converts NEITHER row' do
      pizza = product
      legacy_item('sq_item_old', pizza)
      legacy_item('sq_item_new', pizza)

      report = described_class.analyze

      expect(report.counts[:item_collision]).to eq(2)
      expect(report.convertible).to be_empty
      # Sorted by external id, so sq_item_new comes first and each finding
      # names the OTHER row it collides with.
      expect(report.of(:item_collision).map { |f| [f.external_id, f.colliding_external_ids] })
        .to eq([['sq_item_new', ['sq_item_old']], ['sq_item_old', ['sq_item_new']]])
    end

    it 'names both external ids in the collision detail so neither is silently preferred' do
      legacy_item('sq_item_old', product)
      legacy_item('sq_item_new', SpreeSquare::CatalogMapping.first.product)

      detail = described_class.analyze.of(:item_collision).first.detail

      expect(detail).to include('sq_item_new', 'sq_item_old')
      expect(detail).to include('deleted and recreated')
    end

    it 'reports a conflicting target when a live ExternalRef points the same external id elsewhere' do
      other = product('Other')
      legacy_item('sq_item_1', product)
      SpreePos::ExternalRef.create!(pos_connection: connection, resource_type: 'item', external_id: 'sq_item_1',
                                    spree_type: 'Spree::Product', spree_id: other.id)

      finding = described_class.analyze.of(:conflicting_target).first

      expect(finding.external_id).to eq('sq_item_1')
      expect(finding.conflicting_spree_id).to eq(other.id)
    end

    it 'reports a conflicting target when a live ExternalRef already claims the Spree product' do
      pizza = product
      legacy_item('sq_item_new', pizza)
      SpreePos::ExternalRef.create!(pos_connection: connection, resource_type: 'item', external_id: 'sq_item_old',
                                    spree_type: 'Spree::Product', spree_id: pizza.id)

      finding = described_class.analyze.of(:conflicting_target).first

      expect(finding.conflicting_external_id).to eq('sq_item_old')
    end

    it 'reports a row that carries both a product and a variant id as ambiguous, never guessing' do
      mapping = legacy_item('sq_item_1', product)
      mapping.update_columns(spree_variant_id: create(:variant).id)

      finding = described_class.analyze.of(:ambiguous).first

      expect(finding.detail).to include('also carries a variant id')
    end
  end

  describe 'variation mappings' do
    it 'classifies an ordinary variation mapping as convertible' do
      legacy_variation('sq_var_1', create(:variant))

      expect(classification_of(described_class.analyze, 'sq_var_1')).to eq(:convertible)
    end

    it 'surfaces a deleted/recreated collision and converts NEITHER row' do
      variant = create(:variant)
      legacy_variation('sq_var_old', variant)
      legacy_variation('sq_var_new', variant)

      report = described_class.analyze

      expect(report.counts[:variation_collision]).to eq(2)
      expect(report.convertible).to be_empty
    end

    it 'reports a conflicting target when a live ExternalRef already claims the Spree variant' do
      variant = create(:variant)
      legacy_variation('sq_var_new', variant)
      SpreePos::ExternalRef.create!(pos_connection: connection, resource_type: 'variation',
                                    external_id: 'sq_var_old', spree_type: 'Spree::Variant', spree_id: variant.id)

      expect(described_class.analyze.of(:conflicting_target).first.conflicting_external_id).to eq('sq_var_old')
    end
  end

  describe 'category mappings' do
    # The whole reason collision rules are resource-type-specific. In
    # production 37 Square categories collapse onto 8 Spree taxons, and a
    # rule written for items would have reported 29 false conflicts.
    it 'accepts many external categories mapping to one taxon, and converts them all' do
      pizza = category('Pizza')
      legacy_category('sq_cat_1', pizza)
      legacy_category('sq_cat_2', pizza)
      legacy_category('sq_cat_3', pizza)

      report = described_class.analyze

      expect(report.counts[:category_many_to_one_accepted]).to eq(3)
      expect(report.counts[:item_collision]).to eq(0)
      expect(report.counts[:variation_collision]).to eq(0)
      expect(report.convertible.size).to eq(3)
      expect(report.unresolved).to be_empty
    end

    it 'classifies a single category mapping as plainly convertible, not many-to-one' do
      legacy_category('sq_cat_1', category('Pizza'))

      expect(classification_of(described_class.analyze, 'sq_cat_1')).to eq(:convertible)
    end
  end

  describe 'rows that cannot be attributed' do
    it 'reports a mapping with no Spree record recorded at all as a missing target' do
      legacy_item('sq_item_1', product)
      SpreeSquare::CatalogMapping.first.update_columns(spree_product_id: nil)

      finding = described_class.analyze.of(:missing_spree_target).first

      expect(finding.detail).to include('records no product id')
    end

    # The legacy tables carry real foreign keys, so a dangling row cannot
    # arise through ordinary use -- referential integrity is suspended here
    # to reach the analyzer's defensive branch deliberately. ExternalRef
    # itself has no such FK (a dangling ref self-heals on the next sync),
    # so this is the shape the cutover has to stay honest about.
    it 'reports a mapping whose Spree record was deleted as a missing target' do
      pizza = product
      legacy_item('sq_item_1', pizza)
      ActiveRecord::Base.connection.disable_referential_integrity do
        SpreeSquare::CatalogMapping.first.update_columns(spree_product_id: pizza.id + 10_000)
      end

      finding = described_class.analyze.of(:missing_spree_target).first

      expect(finding.detail).to include('no longer exists')
    end

    it 'reports a mapping whose store has no catalog-source connection' do
      connection.update!(catalog_role: 'none')
      legacy_item('sq_item_1', product)

      finding = described_class.analyze.of(:missing_connection).first

      expect(finding.pos_connection_id).to be_nil
      expect(finding.detail).to include("catalog_role 'source'")
    end

    it 'pins every row to an explicitly supplied connection instead of resolving one per row' do
      connection.update!(catalog_role: 'none')
      legacy_item('sq_item_1', product)

      report = described_class.analyze(connection: connection)

      expect(classification_of(report, 'sq_item_1')).to eq(:convertible)
    end
  end

  describe 'tenant isolation' do
    let(:other_store) { create(:store, name: 'Second Franchisee', url: 'second.example.com', code: 'second') }
    let!(:other_connection) do
      create(:pos_connection, store: other_store, provider: 'square', catalog_role: 'source',
                              external_merchant_id: 'MERCHANT_OTHER')
    end

    it 'attributes each mapping to its own store\'s connection' do
      legacy_item('sq_item_here', product)
      legacy_item('sq_item_there', create(:product, stores: [other_store], name: 'Theirs').tap { |p| p.update!(store: other_store) })

      report = described_class.analyze

      expect(report.findings.map { |f| [f.external_id, f.pos_connection_id] }).to contain_exactly(
        ['sq_item_here', connection.id],
        ['sq_item_there', other_connection.id]
      )
    end

    it 'does not see another connection\'s ExternalRef as a conflict' do
      pizza = product
      legacy_item('sq_item_1', pizza)
      SpreePos::ExternalRef.create!(pos_connection: other_connection, resource_type: 'item',
                                    external_id: 'sq_item_1', spree_type: 'Spree::Product', spree_id: pizza.id)

      expect(classification_of(described_class.analyze, 'sq_item_1')).to eq(:convertible)
    end
  end

  describe 'already-migrated rows' do
    it 'classifies a row whose ExternalRef matches exactly as unchanged' do
      pizza = product
      legacy_item('sq_item_1', pizza, version: 3)
      SpreePos::ExternalRef.create!(pos_connection: connection, resource_type: 'item', external_id: 'sq_item_1',
                                    spree_type: 'Spree::Product', spree_id: pizza.id, external_version: 3)

      expect(classification_of(described_class.analyze, 'sq_item_1')).to eq(:unchanged)
    end

    it 'classifies a row whose ExternalRef has since been re-synced as already represented, and leaves it alone' do
      pizza = product
      legacy_item('sq_item_1', pizza, version: 3)
      ref = SpreePos::ExternalRef.create!(pos_connection: connection, resource_type: 'item',
                                          external_id: 'sq_item_1', spree_type: 'Spree::Product',
                                          spree_id: pizza.id, external_version: 9)

      described_class.migrate!

      expect(classification_of(described_class.analyze, 'sq_item_1')).to eq(:already_represented)
      expect(ref.reload.external_version).to eq(9)
    end
  end

  # The explicit plan an operator signs off before a production cutover.
  # Distinct from the state report: this says what is about to HAPPEN.
  describe 'the mutation plan' do
    it 'states exactly what would be inserted, per resource type' do
      legacy_item('sq_item_1', product)
      legacy_category('sq_cat_1', category('Pizza'))

      plan = described_class.analyze.mutation_plan

      expect(plan).to include('MUTATION PLAN')
      expect(plan).to include('Would INSERT 2 SpreePos::ExternalRef row(s)')
      expect(plan).to match(/item\s+convertible\s+1/)
      expect(plan).to match(/category\s+convertible\s+1/)
    end

    # The three zeros are the whole safety claim in one place: this migration
    # only ever inserts, and never touches the legacy tables it reads.
    it 'states plainly that it updates nothing, deletes nothing and touches no legacy row' do
      legacy_item('sq_item_1', product)

      plan = described_class.analyze.mutation_plan

      expect(plan).to include('Would UPDATE   0 rows')
      expect(plan).to include('Would DELETE   0 rows')
      expect(plan).to include('Would TOUCH    0 legacy rows')
    end

    it 'breaks the plan down per connection, so a franchise cutover is reviewable' do
      legacy_item('sq_item_1', product)

      expect(described_class.analyze.mutation_plan).to match(/connection #{connection.id} \(MERCHANT_MAIN\): 1 row/)
    end

    it 'warns up front that it would refuse when rows are unresolved' do
      pizza = product
      legacy_item('sq_item_old', pizza)
      legacy_item('sq_item_new', pizza)

      expect(described_class.analyze.mutation_plan).to include('WOULD REFUSE')
    end

    it 'says it would proceed when nothing is unresolved' do
      legacy_item('sq_item_1', product)

      expect(described_class.analyze.mutation_plan).to include('The mutation would proceed')
    end
  end

  describe 'the mutation' do
    it 'creates an ExternalRef for every convertible row, carrying the legacy version metadata' do
      pizza = product
      legacy_item('sq_item_1', pizza, version: 5)

      described_class.migrate!
      ref = SpreePos::ExternalRef.find_by(external_id: 'sq_item_1')

      expect(ref.pos_connection).to eq(connection)
      expect(ref.resource_type).to eq('item')
      expect(ref.product).to eq(pizza)
      expect(ref.external_version).to eq(5)
    end

    it 'is idempotent: a second run writes nothing' do
      legacy_item('sq_item_1', product)
      legacy_category('sq_cat_1', category('Pizza'))
      described_class.migrate!

      expect { described_class.migrate! }.not_to change(SpreePos::ExternalRef, :count).from(2)
    end

    it 'reports what it applied, and applies nothing on the second run' do
      legacy_item('sq_item_1', product)

      expect(described_class.migrate!.applied.size).to eq(1)
      expect(described_class.migrate!.applied).to be_empty
    end

    it 'leaves conflicts unresolved rather than picking a winner' do
      pizza = product
      legacy_item('sq_item_old', pizza)
      legacy_item('sq_item_new', pizza)

      described_class.migrate!(allow_unresolved: true)

      expect(SpreePos::ExternalRef.count).to eq(0)
      expect(described_class.analyze.counts[:item_collision]).to eq(2)
    end

    it 'migrates the convertible rows even when other rows conflict' do
      pizza = product
      legacy_item('sq_item_old', pizza)
      legacy_item('sq_item_new', pizza)
      legacy_category('sq_cat_1', category('Pizza'))

      described_class.migrate!(allow_unresolved: true)

      expect(SpreePos::ExternalRef.pluck(:external_id)).to eq(['sq_cat_1'])
    end

    # THE REFUSAL GATE. Unresolved rows mean a human has not finished
    # deciding, and mutating anyway would act on a plan nobody signed off.
    it 'REFUSES to mutate at all when any row still needs human resolution' do
      pizza = product
      legacy_item('sq_item_old', pizza)
      legacy_item('sq_item_new', pizza)

      expect { described_class.migrate! }
        .to raise_error(SpreeSquare::LegacyCatalogReconciliation::Migrator::InvariantViolation,
                        /REFUSING TO MUTATE/)
    end

    it 'writes nothing at all when it refuses, not even the convertible rows' do
      pizza = product
      legacy_item('sq_item_old', pizza)
      legacy_item('sq_item_new', pizza)
      legacy_category('sq_cat_1', category('Pizza'))

      expect { described_class.migrate! rescue nil }.not_to change(SpreePos::ExternalRef, :count).from(0)
    end

    it 'names the classifications blocking it, so the operator knows what to look at' do
      pizza = product
      legacy_item('sq_item_old', pizza)
      legacy_item('sq_item_new', pizza)

      expect { described_class.migrate! }.to raise_error(/item_collision: 2/)
    end

    it 'proceeds when explicitly told the unresolved rows have been reviewed' do
      pizza = product
      legacy_item('sq_item_old', pizza)
      legacy_item('sq_item_new', pizza)
      legacy_category('sq_cat_1', category('Pizza'))

      expect { described_class.migrate!(allow_unresolved: true) }
        .to change(SpreePos::ExternalRef, :count).from(0).to(1)
    end

    it 'needs no override when nothing is unresolved' do
      legacy_item('sq_item_1', product)

      expect { described_class.migrate! }.to change(SpreePos::ExternalRef, :count).from(0).to(1)
    end

    it 'never deletes or edits a legacy mapping row' do
      mapping = legacy_item('sq_item_1', product)
      taxon_mapping = legacy_category('sq_cat_1', category('Pizza'))

      described_class.migrate!

      expect(SpreeSquare::CatalogMapping.count).to eq(1)
      expect(SpreeSquare::TaxonMapping.count).to eq(1)
      expect(mapping.reload.square_catalog_object_id).to eq('sq_item_1')
      expect(taxon_mapping.reload.square_category_id).to eq('sq_cat_1')
    end

    it 'never overwrites an ExternalRef that conflicts with the legacy row' do
      other = product('Other')
      legacy_item('sq_item_1', product)
      ref = SpreePos::ExternalRef.create!(pos_connection: connection, resource_type: 'item',
                                          external_id: 'sq_item_1', spree_type: 'Spree::Product', spree_id: other.id)

      described_class.migrate!(allow_unresolved: true)

      expect(ref.reload.spree_id).to eq(other.id)
    end
  end
end
