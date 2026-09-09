require 'json'

# Characterization spec, written in Phase 0 of the multi-POS/multi-location
# plan before CatalogImporter moves anywhere — the behaviour asserted here
# must survive the Phase 2 extraction unchanged (a changed expectation
# during that phase is itself a stop signal, per the plan).
#
# Object identities below come from the real, officially-documented Square
# object shapes recorded in spec/fixtures/square/search_catalog_objects.json
# (see that directory's README.md for exact provenance) — not invented ids.
RSpec.describe SpreeSquare::CatalogImporter do
  FIXTURE_PATH = File.join(__dir__, '..', '..', 'fixtures', 'square', 'search_catalog_objects.json')

  def fixture_objects
    JSON.parse(File.read(FIXTURE_PATH))['objects']
  end

  # A minimal stand-in for the Fern SDK's typed CatalogObject — CatalogImporter
  # itself only ever calls #type (to group) and passes the object through, so
  # unlike CatalogObjectMapper's own spec this doesn't need the full
  # `<type>_data` OpenStruct payload attached. See catalog_object_mapper_spec
  # for why a plain double (not instance_double) is deliberate here too.
  def square_object(raw)
    double("Square::Types::CatalogObject(#{raw['type']})", id: raw['id'], type: raw['type'], version: raw['version'])
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
  let(:mapper) { instance_double(SpreeSquare::CatalogObjectMapper) }

  before do
    allow(SpreeSquare::Client).to receive(:instance).and_return(client)
    allow(client).to receive(:catalog).and_return(catalog_api)
    allow(SpreeSquare::CatalogObjectMapper).to receive(:new).and_return(mapper)
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
