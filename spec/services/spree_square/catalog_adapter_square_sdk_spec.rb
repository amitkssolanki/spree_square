require 'json'

# Regression for the 2026-09-11 production failure: the first real catalog
# import under spree_square 2.0.0 raised NoMethodError reading
# `present_at_location_ids` from the nested Square::Types::CatalogItem
# (docs/b2-cutover-incident-2026-09-11.md in the host repo).
#
# Everything here is a REAL square.rb object, loaded from
# spec/fixtures/square/search_catalog_objects_sdk_46_1.json, a sanitized
# subset of a live square.rb 46.1 catalog response (provenance in that
# directory's README). Only the HTTP boundary is stubbed, and what it
# returns is the SDK's own response type.
RSpec.describe SpreeSquare::CatalogAdapter, 'with real Square SDK objects' do
  let(:fixture_json) { File.read(File.join(__dir__, '..', '..', 'fixtures', 'square', 'search_catalog_objects_sdk_46_1.json')) }
  let(:response) { Square::Types::SearchCatalogObjectsResponse.load(fixture_json) }
  let(:catalog_api) { double('catalog api') }
  let(:client) { instance_double(SpreeSquare::Client, catalog: catalog_api) }
  let(:adapter) { described_class.new(client: client) }
  let(:snapshot) { adapter.fetch_all }
  let(:raw_items) { response.objects.select { |o| o.type == 'ITEM' } }
  let(:restricted_id) { 'FXITM9999999999999999999' }

  before { allow(catalog_api).to receive(:search).and_return(response) }

  def item_dto(id) = snapshot.items.find { |i| i.external_id == id }

  describe 'where Square puts location availability' do
    it 'declares it on the outer catalog object, not on CatalogItem' do
      expect(Square::Types::CatalogObjectBase.fields).to include(:present_at_location_ids, :present_at_all_locations)
      expect(Square::Types::CatalogItem.fields).not_to include(:present_at_location_ids)
    end

    it 'never gives the nested item payload the field, and conversion does not need it' do
      raw_items.each { |item| expect(item.item_data).not_to respond_to(:present_at_location_ids) }

      expect { snapshot }.not_to raise_error
    end

    it "reads a restricted item's locations from the outer object" do
      expect(item_dto(restricted_id).available_at_external_location_ids).to eq(['FXLOC00000000000000001'])
    end

    # Square defaults present_at_all_locations to true. Every item in the live
    # capture was an all-locations item, so this is the production case.
    it 'treats an all-locations item as unrestricted rather than available nowhere' do
      unrestricted = snapshot.items.reject { |i| i.external_id == restricted_id }

      expect(unrestricted).not_to be_empty
      expect(unrestricted.map(&:available_at_external_location_ids)).to all(be_nil)
    end

    # The SDK defines an extra field's accessor on the member CLASS the first
    # time any payload carries that key. In production no item carried
    # present_at_location_ids, so the outer object had no such method either,
    # and calling it directly would have raised again. A fresh member class
    # reproduces that state whatever other specs have loaded.
    it 'does not depend on the SDK having seen present_at_location_ids before' do
      fresh_member = Class.new(Square::Internal::Types::Model) do
        field :item_data, -> { Square::Types::CatalogItem }, optional: true, nullable: false
      end
      raw = JSON.parse(fixture_json)['objects'].find { |o| o['type'] == 'ITEM' && o['id'] != restricted_id }
      object = fresh_member.new(raw)

      expect(object).not_to respond_to(:present_at_location_ids)
      expect { object.present_at_location_ids }.to raise_error(NoMethodError)
      expect(adapter.item_dto(object, {}).available_at_external_location_ids).to be_nil
    end
  end

  describe 'the neutral snapshot' do
    it 'converts every object the response carries' do
      counts = response.objects.map(&:type).tally

      expect(snapshot.items.size).to eq(counts['ITEM'])
      expect(snapshot.categories.size).to eq(counts['CATEGORY'])
      expect(snapshot.taxes.size).to eq(counts['TAX'])
      expect(snapshot.modifier_groups.size).to eq(counts['MODIFIER_LIST'])
    end

    it "carries each item's own fields through", :aggregate_failures do
      images = response.related_objects.to_h { |o| [o.id, o] }

      raw_items.each do |raw|
        dto = item_dto(raw.id)
        data = raw.item_data
        expect(dto.name).to eq(data.name)
        expect(dto.external_version).to eq(raw.version)
        expect(dto.category_external_ids).to eq(Array(data.categories).map(&:id))
        expect(dto.tax_external_ids).to eq(Array(data.tax_ids))
        expect(dto.modifier_group_external_ids)
          .to eq(Array(data.modifier_list_info).reject { |i| i.enabled == false }.map(&:modifier_list_id))
        expect(dto.image_url).to eq(images[Array(data.image_ids).first]&.image_data&.url)
        expect(dto.variations.map(&:external_id)).to eq(data.variations.map(&:id))
        dto.variations.zip(data.variations).each do |variation, raw_variation|
          expect(variation.price_cents).to eq(raw_variation.item_variation_data.price_money.amount)
          expect(variation.currency).to eq(raw_variation.item_variation_data.price_money.currency)
        end
      end
    end

    it 'converts modifier groups with their modifiers and prices', :aggregate_failures do
      response.objects.select { |o| o.type == 'MODIFIER_LIST' }.each do |raw|
        group = snapshot.modifier_groups.find { |g| g.external_id == raw.id }
        data = raw.modifier_list_data
        expect(group.name).to eq(data.name)
        expect(group.selection_type).to eq(data.selection_type)
        expect(group.min_selected).to eq(data.min_selected_modifiers)
        expect(group.max_selected).to eq(data.max_selected_modifiers)
        expect(group.modifiers.map(&:external_id)).to eq(Array(data.modifiers).map(&:id))
        expect(group.modifiers.map(&:price_cents)).to eq(Array(data.modifiers).map { |m| m.modifier_data.price_money&.amount || 0 })
      end
    end

    it 'converts the tax' do
      raw = response.objects.find { |o| o.type == 'TAX' }
      tax = snapshot.taxes.sole

      expect(tax.external_id).to eq(raw.id)
      expect(tax.percentage).to eq(BigDecimal(raw.tax_data.percentage))
      expect(tax.included_in_price).to be(raw.tax_data.inclusion_type == 'INCLUSIVE')
      expect(tax.enabled).to be(true)
    end
  end

  # square.rb 46.x turns an explicit `false` on a declared field into nil
  # (see SpreeSquare::SquareSdkFalseValues). Without the fix both of these
  # read as enabled.
  describe 'values Square sends as false' do
    it 'imports a tax disabled in Square as disabled' do
      tax = square_catalog_object(id: 'FXTAX_OFF', type: 'TAX',
                                  tax_data: { name: 'Tax', percentage: '8.0', inclusion_type: 'ADDITIVE', enabled: false })

      expect(adapter.tax_dto(tax).enabled).to be(false)
    end

    it 'drops a modifier list the item has disabled' do
      item = square_catalog_object(
        id: 'FXITM_MODS', type: 'ITEM',
        item_data: { name: 'Item', variations: [],
                     modifier_list_info: [{ modifier_list_id: 'ON', enabled: true }, { modifier_list_id: 'OFF', enabled: false }] }
      )

      expect(adapter.item_dto(item, {}).modifier_group_external_ids).to eq(['ON'])
    end
  end

  describe 'a full import of the live-derived catalog' do
    let(:store) { Spree::Store.default }
    let(:state) { create(:state, name: 'Ohio', abbr: 'OH') }
    let!(:stock_location) { create(:stock_location, default: true, state: state, country: state.country) }
    let!(:tax_zone) { create(:zone, name: 'OH Sales Tax', kind: 'state').tap { |z| z.members.create!(zoneable: state) } }
    let!(:connection) do
      SpreePos::Connection.create!(store: store, provider: 'square', external_merchant_id: 'sq_merchant_1',
                                    catalog_role: 'source')
    end

    before do
      Spree::ShippingCategory.find_or_create_by!(name: 'Default')
      Spree::Channel.find_or_create_by!(code: 'online') { |c| c.name = 'Online Store'; c.store = store }
      allow(SpreeSquare::Client).to receive(:for_connection).with(connection).and_return(client)
      # CatalogSync downloads each item's primary image; the fixture's image
      # URLs are sanitized placeholders, so serve a 1x1 PNG for them.
      stub_request(:get, %r{\Ahttps://example\.test/catalog-images/}).to_return(
        status: 200, headers: { 'Content-Type' => 'image/png' },
        body: Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=')
      )
    end

    it 'imports every item, variation and category through the real sync', :aggregate_failures do
      variations = raw_items.sum { |i| i.item_data.variations.size }
      result = nil

      expect { result = SpreeSquare::CatalogImporter.call(connection: connection) }.to change(Spree::Product, :count).by(raw_items.size)
      expect(result.items_count).to eq(raw_items.size)
      refs = SpreePos::ExternalRef.where(pos_connection: connection).group(:resource_type).count
      expect(refs).to include('item' => raw_items.size, 'variation' => variations,
                              'category' => response.objects.count { |o| o.type == 'CATEGORY' })
    end
  end
end
