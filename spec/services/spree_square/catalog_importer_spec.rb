require 'json'

# Characterization spec, written in Phase 0 of the multi-POS/multi-location
# plan before CatalogImporter moves anywhere.
#
# B3 UPDATE: the collaborator changed and so did this spec's doubles, but
# NOT its assertions. CatalogImporter used to build a
# SpreeSquare::CatalogObjectMapper and feed it raw Square objects; it now
# builds a SpreePos::CatalogSync and feeds it provider-neutral DTOs. What
# is asserted — the import ORDER (categories, modifier groups, taxes,
# items), cursor pagination, and the reported counts — is unchanged,
# because that behaviour had to be preserved exactly.
#
# Object identities below come from the real, officially-documented Square
# object shapes recorded in spec/fixtures/square/search_catalog_objects.json
# (see that directory's README.md for exact provenance) — not invented ids.
RSpec.describe SpreeSquare::CatalogImporter do
  FIXTURE_PATH = File.join(__dir__, '..', '..', 'fixtures', 'square', 'search_catalog_objects.json')

  def fixture_objects
    JSON.parse(File.read(FIXTURE_PATH))['objects']
  end

  # A minimal stand-in for the Fern SDK's typed CatalogObject. B3: the
  # importer now converts each object to a DTO before handing it on, so
  # these doubles need the `<type>_data` payload the adapter's DTO
  # builders read (they did not before, when the raw object was passed
  # straight through). See catalog_object_mapper_spec for why a plain
  # double (not instance_double) is deliberate here too.
  DATA_KEY = {
    'CATEGORY' => :category_data, 'MODIFIER_LIST' => :modifier_list_data,
    'TAX' => :tax_data, 'ITEM' => :item_data, 'IMAGE' => :image_data
  }.freeze

  def square_object(raw)
    attrs = { id: raw['id'], type: raw['type'], version: raw['version'] }
    key = DATA_KEY[raw['type']]
    attrs[key] = OpenStruct.new(payload_for(raw['type'])) if key
    double("Square::Types::CatalogObject(#{raw['type']})", **attrs)
  end

  # Just enough of each `<type>_data` shape for the adapter's DTO builders;
  # the values themselves are irrelevant to what this spec asserts.
  def payload_for(type)
    case type
    when 'CATEGORY'      then { name: 'Cat' }
    when 'MODIFIER_LIST' then { name: 'List', selection_type: 'SINGLE', min_selected_modifiers: nil,
                                max_selected_modifiers: nil, modifiers: [] }
    when 'TAX'           then { name: 'Tax', percentage: '8.0', inclusion_type: 'ADDITIVE', enabled: true }
    when 'ITEM'          then { name: 'Item', description: nil, image_ids: [], category_id: nil, categories: [],
                                tax_ids: [], modifier_list_info: [], variations: [], present_at_location_ids: [] }
    else {}
    end
  end

  def search_response(objects:, related: [], cursor: nil)
    double('Square::Types::SearchCatalogObjectsResponse',
           objects: objects.map { |o| square_object(o) },
           related_objects: related.map { |o| square_object(o) },
           cursor: cursor)
  end

  let(:raw) { fixture_objects.group_by { |o| o['type'] } }
  let(:category) { raw.fetch('CATEGORY') }
  let(:modifier_list) { raw.fetch('MODIFIER_LIST') }
  let(:tax) { raw.fetch('TAX') }
  let(:item) { raw.fetch('ITEM') }

  let(:client) { instance_double(SpreeSquare::Client) }
  let(:catalog_api) { double('catalog_api') }
  # B3: the importer's collaborator is now the provider-neutral sync,
  # receiving DTOs.
  let(:mapper) { instance_double(SpreePos::CatalogSync) }

  before do
    allow(SpreeSquare::Client).to receive(:instance).and_return(client)
    allow(client).to receive(:catalog).and_return(catalog_api)
    allow(SpreePos::CatalogSync).to receive(:new).and_return(mapper)
  end

  describe '#call' do
    context 'a single page (no cursor)' do
      before do
        allow(catalog_api).to receive(:search)
          .with(object_types: %w[ITEM CATEGORY MODIFIER_LIST TAX], include_related_objects: true, cursor: nil)
          .and_return(search_response(objects: category + modifier_list + tax + item))
      end

      it 'maps categories, then modifier lists, then taxes, then items — in that order' do
        expect(mapper).to receive(:map_category).ordered
        expect(mapper).to receive(:map_modifier_list).ordered
        expect(mapper).to receive(:map_tax).ordered
        expect(mapper).to receive(:map_item).ordered

        described_class.call
      end

      it 'reports how many of each type it imported' do
        allow(mapper).to receive(:map_category)
        allow(mapper).to receive(:map_modifier_list)
        allow(mapper).to receive(:map_tax)
        allow(mapper).to receive(:map_item)

        result = described_class.call

        expect(result.categories_count).to eq(category.size)
        expect(result.modifier_lists_count).to eq(modifier_list.size)
        expect(result.taxes_count).to eq(tax.size)
        expect(result.items_count).to eq(item.size)
      end
    end

    context 'a paginated response (the categories/modifier-lists/taxes page arrives before the items page)' do
      before do
        # Real Square catalogs of restaurant size run low hundreds of items —
        # this is exactly the shape CatalogImporter#fetch_all is written to
        # loop over: keep requesting with the returned cursor until blank.
        allow(catalog_api).to receive(:search)
          .with(object_types: %w[ITEM CATEGORY MODIFIER_LIST TAX], include_related_objects: true, cursor: nil)
          .and_return(search_response(objects: category + modifier_list + tax, related: [], cursor: 'page-2'))
        allow(catalog_api).to receive(:search)
          .with(object_types: %w[ITEM CATEGORY MODIFIER_LIST TAX], include_related_objects: true, cursor: 'page-2')
          .and_return(search_response(objects: item, cursor: nil))
      end

      it 'follows the cursor until it is blank, aggregating both pages' do
        allow(mapper).to receive(:map_category)
        allow(mapper).to receive(:map_modifier_list)
        allow(mapper).to receive(:map_tax)
        allow(mapper).to receive(:map_item)

        result = described_class.call

        expect(catalog_api).to have_received(:search).twice
        expect(result.items_count).to eq(item.size)
        expect(result.categories_count).to eq(category.size)
      end

      it 'still maps every category/list/tax (page 1) before any item (page 2)' do
        expect(mapper).to receive(:map_category).ordered
        expect(mapper).to receive(:map_modifier_list).ordered
        expect(mapper).to receive(:map_tax).ordered
        expect(mapper).to receive(:map_item).ordered

        described_class.call
      end
    end
  end
end
