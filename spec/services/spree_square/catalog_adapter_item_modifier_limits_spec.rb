require 'json'

# An item's own limits for one of its modifier lists:
# CatalogItemModifierListInfo.min_selected_modifiers / max_selected_modifiers
# (https://developer.squareup.com/reference/square/objects/CatalogItemModifierListInfo).
# The Square sandbox's Build-Your-Own Bowl sets 0..5 on "Extra Toppings", a
# list with no limits of its own; before this the limits were dropped and a
# 6th topping was accepted. Real square.rb objects throughout.
RSpec.describe SpreeSquare::CatalogAdapter, 'per-item modifier limits' do
  let(:adapter) { described_class.new }

  def item_object(infos)
    json = { 'objects' => [{ 'type' => 'ITEM', 'id' => 'ITEM1', 'version' => 1,
                             'item_data' => { 'name' => 'Build-Your-Own Bowl', 'modifier_list_info' => infos,
                                              'variations' => [] } }] }
    Square::Types::SearchCatalogObjectsResponse.load(JSON.generate(json)).objects.first
  end

  def overrides(*infos)
    adapter.item_dto(item_object(infos), {}).modifier_group_overrides
              .map { |o| [o.modifier_group_external_id, o.min_selected, o.max_selected] }
  end

  it "carries the bowl's 0..5 toppings override, as recorded from the sandbox" do
    expect(overrides({ 'modifier_list_id' => 'TOPPINGS', 'min_selected_modifiers' => 0, 'max_selected_modifiers' => 5,
                       'enabled' => true })).to eq([['TOPPINGS', 0, 5]])
  end

  it 'reads -1 on both (or both absent) as no override, so the list applies' do
    expect(overrides({ 'modifier_list_id' => 'L1', 'min_selected_modifiers' => -1, 'max_selected_modifiers' => -1 },
                     { 'modifier_list_id' => 'L2' })).to eq([])
  end

  it 'leaves an unset field nil when only the other one is set' do
    expect(overrides({ 'modifier_list_id' => 'L1', 'min_selected_modifiers' => -1, 'max_selected_modifiers' => 3 },
                     { 'modifier_list_id' => 'L2', 'min_selected_modifiers' => 2 }))
      .to eq([['L1', nil, 3], ['L2', 2, nil]])
  end

  it 'reads an invalid value below -1 as no minimum / no maximum (0)' do
    expect(overrides({ 'modifier_list_id' => 'L1', 'min_selected_modifiers' => -5, 'max_selected_modifiers' => -2 }))
      .to eq([['L1', 0, 0]])
  end

  it 'drops the override of a list disabled on the item, together with the list' do
    dto = adapter.item_dto(item_object([{ 'modifier_list_id' => 'OFF', 'enabled' => false, 'max_selected_modifiers' => 2 },
                                        { 'modifier_list_id' => 'ON', 'max_selected_modifiers' => 2 }]), {})

    expect(dto.modifier_group_external_ids).to eq(['ON'])
    expect(dto.modifier_group_overrides.map(&:modifier_group_external_id)).to eq(['ON'])
  end

  it 'reads the override from the live-derived SDK fixture' do
    fixture = File.read(File.join(__dir__, '..', '..', 'fixtures', 'square', 'search_catalog_objects_sdk_46_1.json'))
    raw = Square::Types::SearchCatalogObjectsResponse.load(fixture).objects.find { |o| o.id == 'FXITM0000000000000000002' }

    expect(adapter.item_dto(raw, {}).modifier_group_overrides.find { |o| o.modifier_group_external_id == 'FXMDL0000000000000000003' })
      .to have_attributes(min_selected: 0, max_selected: 5)
  end

  describe 'through the real sync' do
    let(:store) { Spree::Store.default.presence || create(:store) }
    let(:connection) { create(:pos_connection, store: store, provider: 'square') }
    let(:sync) { SpreePos::CatalogSync.new(connection: connection) }

    before { Spree::ShippingCategory.find_or_create_by!(name: 'Default') }

    it 'stores the limits on the product, not on the shared list' do
      list = Square::Types::SearchCatalogObjectsResponse.load(JSON.generate('objects' => [
        { 'type' => 'MODIFIER_LIST', 'id' => 'TOPPINGS', 'version' => 1,
          'modifier_list_data' => { 'name' => 'Extra Toppings', 'selection_type' => 'MULTIPLE',
                                    'modifiers' => [{ 'type' => 'MODIFIER', 'id' => 'CORN', 'version' => 1,
                                                      'modifier_data' => { 'name' => 'Corn Salsa',
                                                                           'price_money' => { 'amount' => 75, 'currency' => 'USD' } } }] } }
      ])).objects.first
      sync.map_modifier_list(adapter.modifier_group_dto(list))
      sync.map_item(adapter.item_dto(item_object([{ 'modifier_list_id' => 'TOPPINGS', 'min_selected_modifiers' => 0,
                                                     'max_selected_modifiers' => 5 }]), {}))

      pml = SpreePos::ProductModifierList.sole
      expect([pml.min_selected_modifiers, pml.max_selected_modifiers]).to eq([0, 5])
      expect([pml.modifier_list.min_selected_modifiers, pml.modifier_list.max_selected_modifiers]).to eq([nil, nil])
      expect([pml.effective_min_selected, pml.effective_max_selected]).to eq([0, 5])
    end
  end
end
