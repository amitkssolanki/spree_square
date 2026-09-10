# The production-shaped B2 rehearsal (brief section 10).
#
# Every mutation below passes `allow_unresolved: true`. That is the point of
# the fixture: it deliberately contains collisions, an ambiguous row and an
# unattributable one, and the migrator now REFUSES by default when any row
# still needs human resolution. These examples are the reviewed-and-proceed
# case, which is exactly how a real cutover runs once an operator has looked
# at each unresolved row and decided to migrate the rest.
#
# This is deliberately ONE long fixture rather than a set of small ones: the
# thing being validated is not any single classification (those have their
# own spec next door) but that the whole cutover behaves correctly on a
# database shaped like the real one, with the real 37-categories-to-8-taxons
# ratio, real collisions, and pre-existing ExternalRefs all present at once.
#
# It runs the full operational cycle:
#
#   dry run -> inspect/classify -> mutation -> dry run -> mutation
#
# Production is never touched. Every row below is built here and thrown away
# with the transaction at the end of each example.
RSpec.describe 'SpreeSquare::LegacyCatalogReconciliation on a production-shaped database' do
  # ------------------------------------------------------------------
  # Store A: the live franchisee, one Square merchant, the Phase 3 shape.
  # ------------------------------------------------------------------
  let(:store_a) { Spree::Store.default }
  let!(:connection_a) do
    create(:pos_connection, store: store_a, catalog_role: 'source', external_merchant_id: 'MERCHANT_A')
  end

  # Store B: a second franchisee on its own merchant account. Present to
  # prove attribution and isolation, not for volume.
  let(:store_b) { create(:store, name: 'Franchisee B', url: 'b.example.com', code: 'fran-b') }
  let!(:connection_b) do
    create(:pos_connection, store: store_b, catalog_role: 'source', external_merchant_id: 'MERCHANT_B')
  end

  # Store C: onboarded but never connected. Its mappings have nowhere to go
  # and must be reported, not guessed at.
  let(:store_c) { create(:store, name: 'Franchisee C', url: 'c.example.com', code: 'fran-c') }

  # The real production ratio: 37 Square categories collapsing onto 8 Spree
  # taxons. One taxon carries a single category (an ordinary convertible
  # row); the other seven carry the remaining 36 between them.
  CATEGORY_DISTRIBUTION = [1, 5, 5, 5, 5, 5, 6, 5].freeze

  def product_in(store, name)
    create(:product, name: name).tap { |p| p.update!(store: store) }
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

  def external_ref(connection, resource_type, external_id, record_type, record_id, version: nil)
    SpreePos::ExternalRef.create!(pos_connection: connection, resource_type: resource_type,
                                  external_id: external_id, spree_type: record_type, spree_id: record_id,
                                  external_version: version)
  end

  before do
    build_categories!
    build_items!
    build_variations!
    build_other_tenants!
    build_pre_existing_refs!
  end

  # 37 category mappings -> 8 taxons.
  def build_categories!
    external_id = 0
    CATEGORY_DISTRIBUTION.each_with_index do |mappings_for_this_taxon, taxon_index|
      taxon = Spree::Category.create!(name: "Menu Section #{taxon_index}", store: store_a)
      mappings_for_this_taxon.times do
        SpreeSquare::TaxonMapping.create!(square_category_id: format('sq_cat_%02d', external_id),
                                          taxon: taxon, square_version: 1)
        external_id += 1
      end
    end
  end

  def build_items!
    10.times { |i| legacy_item(format('sq_item_%02d', i), product_in(store_a, "Dish #{i}")) }

    # Deleted and recreated in Square: a new catalog object id for the same
    # dish. Two legacy rows, one Spree product, and ExternalRef's partial
    # unique index permits only one of them.
    collided = product_in(store_a, 'Recreated Dish')
    legacy_item('sq_item_dup_new', collided)
    legacy_item('sq_item_dup_old', collided)

    # Malformed legacy row: typed as an item but also carrying a variant id.
    # Nothing in the legacy schema forbids this, so the cutover has to have
    # an answer for it that is not a guess.
    ambiguous = legacy_item('sq_item_ambiguous', product_in(store_a, 'Ambiguous Dish'))
    ambiguous.update_columns(spree_variant_id: create(:variant).id)

    @already_migrated = product_in(store_a, 'Already Migrated Dish')
    legacy_item('sq_item_unchanged', @already_migrated, version: 4)

    @resynced = product_in(store_a, 'Resynced Dish')
    legacy_item('sq_item_resynced', @resynced, version: 4)

    @conflicted = product_in(store_a, 'Conflicted Dish')
    legacy_item('sq_item_conflict', @conflicted)

    # Same external id as a row that already exists under the OTHER
    # merchant. Square catalog object ids are unique per merchant, not
    # globally, so this is an ordinary shape, not a conflict.
    @shared_id_product = product_in(store_a, 'Shared Id Dish')
    legacy_item('sq_item_shared_id', @shared_id_product)
  end

  def build_variations!
    8.times { |i| legacy_variation(format('sq_var_%02d', i), create(:variant)) }

    collided = create(:variant)
    legacy_variation('sq_var_dup_new', collided)
    legacy_variation('sq_var_dup_old', collided)
  end

  def build_other_tenants!
    legacy_item('sq_item_b_00', product_in(store_b, 'B Dish'))
    legacy_item('sq_item_c_00', product_in(store_c, 'C Dish'))
  end

  def build_pre_existing_refs!
    # Already migrated at the same version: nothing to do.
    external_ref(connection_a, 'item', 'sq_item_unchanged', 'Spree::Product', @already_migrated.id, version: 4)
    # Migrated, then re-synced from Square since: the live version is newer
    # than the legacy row's and must not be walked backwards.
    external_ref(connection_a, 'item', 'sq_item_resynced', 'Spree::Product', @resynced.id, version: 9)
    # A different external id already claims the Spree product the legacy
    # row wants.
    external_ref(connection_a, 'item', 'sq_item_conflict_other', 'Spree::Product', @conflicted.id)
    # Merchant B's own row, sharing an external id with one of A's.
    external_ref(connection_b, 'item', 'sq_item_shared_id', 'Spree::Product', product_in(store_b, 'B Shared').id)
  end

  let(:legacy_catalog_count) { SpreeSquare::CatalogMapping.count }
  let(:legacy_taxon_count) { SpreeSquare::TaxonMapping.count }
  let(:pre_existing_ref_count) { 4 }

  # Every expected classification count, stated once. The whole point of
  # the fixture is that these are exact rather than approximate.
  EXPECTED_FIRST_PASS = {
    convertible: 21,
    category_many_to_one_accepted: 36,
    already_represented: 1,
    unchanged: 1,
    missing_connection: 1,
    missing_spree_target: 0,
    duplicate_legacy_mapping: 0,
    item_collision: 2,
    variation_collision: 2,
    conflicting_target: 1,
    ambiguous: 1
  }.freeze

  it 'builds the intended production shape' do
    expect(legacy_taxon_count).to eq(37)
    expect(Spree::Category.where(store: store_a).count).to eq(8)
    expect(legacy_catalog_count).to eq(29)
    expect(SpreePos::ExternalRef.count).to eq(pre_existing_ref_count)
  end

  describe 'step 1: the first dry run' do
    subject(:report) { SpreeSquare::LegacyCatalogReconciliation.analyze }

    it 'classifies every legacy row exactly once' do
      expect(report.total).to eq(legacy_catalog_count + legacy_taxon_count)
      expect(report.counts).to eq(EXPECTED_FIRST_PASS)
    end

    it 'writes nothing' do
      expect { report }.not_to change(SpreePos::ExternalRef, :count).from(pre_existing_ref_count)
    end

    it 'does not report a single one of the 37 categories as a conflict' do
      category_findings = report.findings.select { |f| f.resource_type == 'category' }

      expect(category_findings.size).to eq(37)
      expect(category_findings.map(&:classification).uniq)
        .to contain_exactly(:convertible, :category_many_to_one_accepted)
      expect(category_findings).to all(be_convertible)
    end

    it 'surfaces both halves of the item collision and both halves of the variation collision' do
      expect(report.of(:item_collision).map(&:external_id)).to eq(%w[sq_item_dup_new sq_item_dup_old])
      expect(report.of(:variation_collision).map(&:external_id)).to eq(%w[sq_var_dup_new sq_var_dup_old])
    end

    it 'attributes each tenant\'s mappings to that tenant\'s own connection' do
      by_id = report.findings.to_h { |f| [f.external_id, f.pos_connection_id] }

      expect(by_id['sq_item_00']).to eq(connection_a.id)
      expect(by_id['sq_item_b_00']).to eq(connection_b.id)
      expect(by_id['sq_item_c_00']).to be_nil
    end

    it 'treats an external id shared with another merchant as ordinary, not conflicting' do
      expect(report.findings.find { |f| f.external_id == 'sq_item_shared_id' }.classification).to eq(:convertible)
    end

    it 'lists exactly the rows a human has to resolve before the cutover' do
      expect(report.unresolved.map(&:classification).tally).to eq(
        item_collision: 2, variation_collision: 2, conflicting_target: 1, ambiguous: 1, missing_connection: 1
      )
      expect(report).not_to be_convertible
    end

    it 'renders a report naming every unresolved row' do
      rendered = report.to_s

      expect(rendered).to include('sq_item_dup_old', 'sq_var_dup_old', 'sq_item_conflict',
                                  'sq_item_ambiguous', 'sq_item_c_00')
      expect(rendered).to include('Needs resolution before cutover (7)')
    end

    it 'is byte-identical when run twice against unchanged data' do
      expect(SpreeSquare::LegacyCatalogReconciliation.analyze.to_s).to eq(report.to_s)
    end
  end

  describe 'step 2: the mutation' do
    subject!(:result) { SpreeSquare::LegacyCatalogReconciliation.migrate!(allow_unresolved: true) }

    it 'creates one ExternalRef per convertible row and nothing else' do
      expect(result.applied.size).to eq(57)
      expect(SpreePos::ExternalRef.count).to eq(pre_existing_ref_count + 57)
    end

    it 'migrates all 37 categories, many-to-one included' do
      refs = SpreePos::ExternalRef.where(resource_type: 'category')

      expect(refs.count).to eq(37)
      expect(refs.distinct.count(:spree_id)).to eq(8)
    end

    it 'leaves both collisions unmigrated' do
      expect(SpreePos::ExternalRef.where(external_id: %w[sq_item_dup_new sq_item_dup_old
                                                          sq_var_dup_new sq_var_dup_old])).to be_empty
    end

    it 'leaves the re-synced ExternalRef at its newer live version' do
      expect(SpreePos::ExternalRef.find_by(external_id: 'sq_item_resynced').external_version).to eq(9)
    end

    it 'leaves the conflicting ExternalRef pointed where it was' do
      expect(SpreePos::ExternalRef.find_by(external_id: 'sq_item_conflict')).to be_nil
      expect(SpreePos::ExternalRef.find_by(external_id: 'sq_item_conflict_other').spree_id).to eq(@conflicted.id)
    end

    it 'preserves the legacy version metadata on the rows it did migrate' do
      expect(SpreePos::ExternalRef.find_by(external_id: 'sq_item_00').external_version).to eq(1)
    end

    it 'leaves every legacy row intact' do
      expect(SpreeSquare::CatalogMapping.count).to eq(29)
      expect(SpreeSquare::TaxonMapping.count).to eq(37)
    end
  end

  describe 'steps 3 and 4: the second dry run and the second mutation' do
    before { SpreeSquare::LegacyCatalogReconciliation.migrate!(allow_unresolved: true) }

    it 'reports every migrated row as unchanged and nothing as convertible' do
      report = SpreeSquare::LegacyCatalogReconciliation.analyze

      expect(report.counts).to eq(
        convertible: 0,
        category_many_to_one_accepted: 0,
        already_represented: 1,
        unchanged: 58,
        missing_connection: 1,
        missing_spree_target: 0,
        duplicate_legacy_mapping: 0,
        item_collision: 2,
        variation_collision: 2,
        conflicting_target: 1,
        ambiguous: 1
      )
    end

    it 'still lists exactly the same unresolved rows: the mutation resolved none of them' do
      expect(SpreeSquare::LegacyCatalogReconciliation.analyze.unresolved.size).to eq(7)
    end

    it 'creates no duplicates on a second mutation' do
      expect { SpreeSquare::LegacyCatalogReconciliation.migrate!(allow_unresolved: true) }
        .not_to change(SpreePos::ExternalRef, :count).from(pre_existing_ref_count + 57)
    end

    it 'applies nothing on a second mutation' do
      expect(SpreeSquare::LegacyCatalogReconciliation.migrate!(allow_unresolved: true).applied).to be_empty
    end

    it 'still leaves every legacy row intact' do
      SpreeSquare::LegacyCatalogReconciliation.migrate!(allow_unresolved: true)

      expect(SpreeSquare::CatalogMapping.count).to eq(29)
      expect(SpreeSquare::TaxonMapping.count).to eq(37)
    end
  end
end
