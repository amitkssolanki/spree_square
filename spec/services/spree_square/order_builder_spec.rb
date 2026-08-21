RSpec.describe SpreeSquare::OrderBuilder do
  # Creating a line item on an already-"complete" order (a shortcut real
  # checkout never takes) fires Spree's after_save :update_inventory, which
  # expects a fully-formed checkout-created shipment/inventory-unit graph
  # and blows up on our hand-assembled one. OrderBuilder only reads
  # line_items/variant/price data — it has no interest in real inventory
  # unit bookkeeping, so it's correct to skip that callback for this spec.
  around do |example|
    Spree::LineItem.skip_callback(:save, :after, :update_inventory)
    example.run
    Spree::LineItem.set_callback(:save, :after, :update_inventory)
  end

  let(:stock_location) { create(:stock_location) }
  let!(:location_mapping) do
    SpreeSquare::LocationMapping.create!(stock_location: stock_location, square_location_id: 'sq_loc_1')
  end

  let(:variant) { create(:variant) }
  let!(:catalog_mapping) do
    SpreeSquare::CatalogMapping.create!(
      square_catalog_object_id: 'sq_variation_1',
      square_object_type: SpreeSquare::CatalogMapping::ITEM_VARIATION,
      variant: variant
    )
  end

  # The :order factory derives email from its associated user, ignoring an
  # explicit email: override — assert against order.email itself rather
  # than a literal string.
  let(:order) { create(:order, state: 'complete', completed_at: Time.current) }
  let!(:shipment) { create(:shipment, order: order, stock_location: stock_location) }
  let!(:line_item) { create(:line_item, order: order, variant: variant, quantity: 2, price: 16.95) }

  # .reload: `order` may already have cached an empty `shipments`
  # association from before the `let!(:shipment)` created one.
  subject(:payload) { described_class.call(order.reload) }

  it 'targets the Square location mapped from the order\'s stock location' do
    expect(payload[:location_id]).to eq('sq_loc_1')
  end

  it 'uses the Spree order number as the reference_id' do
    expect(payload[:reference_id]).to eq(order.number)
  end

  it 'includes a PICKUP fulfillment so there is something for the kitchen to advance' do
    fulfillment = payload[:fulfillments].first

    expect(fulfillment[:type]).to eq('PICKUP')
    expect(fulfillment[:pickup_details][:recipient][:email_address]).to eq(order.email)
  end

  describe 'a line item with no modifiers' do
    it 'maps the base price straight through with the catalog_object_id' do
      built = payload[:line_items].first

      expect(built[:catalog_object_id]).to eq('sq_variation_1')
      expect(built[:quantity]).to eq('2')
      expect(built[:base_price_money]).to eq(amount: 1695, currency: 'USD')
      expect(built[:modifiers]).to eq([])
    end
  end

  describe 'a line item with modifiers' do
    before do
      SpreeSquare::LineItemModifier.create!(
        line_item: line_item,
        square_modifier_id: 'sq_mod_1',
        name_snapshot: 'Extra cheese',
        price_cents_snapshot: 150
      )
    end

    it 'subtracts the modifier snapshot total from price to get the true base price' do
      # line_item.price (16.95) already has the +$1.50 modifier baked in
      # (per the M4 design) — base_price_money must be the price *without*
      # that, since Square itemizes modifiers separately.
      built = payload[:line_items].first

      expect(built[:base_price_money]).to eq(amount: 1545, currency: 'USD')
    end

    it 'includes the modifier as its own entry, from the snapshot — not a live Modifier lookup' do
      built = payload[:line_items].first
      modifier = built[:modifiers].first

      expect(modifier[:catalog_object_id]).to eq('sq_mod_1')
      expect(modifier[:name]).to eq('Extra cheese')
      expect(modifier[:base_price_money]).to eq(amount: 150, currency: 'USD')
    end
  end

  describe 'a line item whose variant has no catalog mapping (never synced from Square)' do
    let(:unmapped_variant) { create(:variant) }
    let!(:line_item) { create(:line_item, order: order, variant: unmapped_variant, quantity: 1, price: 5.00) }

    it 'still builds a line item (falls back to name + price, no catalog_object_id)' do
      built = payload[:line_items].first

      expect(built[:catalog_object_id]).to be_nil
      expect(built[:name]).to eq(unmapped_variant.name)
      expect(built[:base_price_money]).to eq(amount: 500, currency: 'USD')
    end
  end

  describe 'a line item whose product carries a synced Square tax' do
    # Builds the tax_category through the real Phase 8 pipeline
    # (SpreeSquare::CatalogObjectMapper#map_tax/#resolve_tax_category) rather
    # than hand-assembling TaxCategoryMapping/TaxRate rows — matches
    # catalog_object_mapper_tax_spec.rb's own established pattern and
    # exercises the exact path production data actually goes through.
    let(:state) { create(:state, name: 'Ohio', abbr: 'OH') }
    let!(:tax_zone) { create(:zone, name: 'OH Sales Tax', kind: 'state').tap { |z| z.members.create!(zoneable: state) } }
    let!(:tax_default_stock_location) { create(:stock_location, default: true, state: state, country: state.country) }
    let(:mapper) { SpreeSquare::CatalogObjectMapper.new }

    def square_object(id:, type:, version: 1, **data_by_key)
      data_key = "#{type.downcase}_data"
      double("Square::Types::CatalogObject(#{type})", id: id, type: type, version: version,
                                                        **{ data_key.to_sym => OpenStruct.new(data_by_key[data_key.to_sym] || {}) })
    end

    let(:tax_category) do
      mapper.map_tax(square_object(id: 'sq_tax_1', type: 'TAX',
                                    tax_data: { name: 'Sales Tax', percentage: '8.0', enabled: true, inclusion_type: 'ADDITIVE' }))
      taxed_product = mapper.map_item(square_object(
                                         id: 'sq_item_1', type: 'ITEM',
                                         item_data: { name: 'Taxable Reference Item', description: nil, variations: [],
                                                      image_ids: nil, category_id: nil, categories: nil,
                                                      modifier_list_info: nil, tax_ids: ['sq_tax_1'] }
                                       ))
      taxed_product.tax_category
    end

    before do
      Spree::ShippingCategory.find_or_create_by!(name: 'Default')
      Spree::Channel.find_or_create_by!(code: 'online') { |c| c.name = 'Online Store'; c.store = Spree::Store.default }
      variant.product.update!(tax_category: tax_category)
    end

    it 'lists the Square tax once at the order level, scoped LINE_ITEM and auto_applied' do
      tax = payload[:taxes].first

      expect(payload[:taxes].size).to eq(1)
      expect(tax[:catalog_object_id]).to eq('sq_tax_1')
      expect(tax[:scope]).to eq('LINE_ITEM')
      expect(tax[:auto_applied]).to eq(true)
    end

    it "references that order-level tax's uid from the line item's applied_taxes" do
      built = payload[:line_items].first
      order_tax_uid = payload[:taxes].first[:uid]

      expect(built[:applied_taxes]).to eq([{ tax_uid: order_tax_uid }])
    end

    describe 'a second, non-taxable line item on the same order' do
      let(:non_taxable_variant) { create(:variant) }
      let!(:second_line_item) do
        create(:line_item, order: order, variant: non_taxable_variant, quantity: 1, price: 4.00)
      end

      it 'only applies the tax to the taxable line item, and still lists the order-level tax once' do
        built_second = payload[:line_items].second

        expect(payload[:taxes].size).to eq(1)
        expect(built_second[:applied_taxes]).to be_nil
      end
    end

    describe 'when that tax is later disabled in Square' do
      # Regression test: found in review before this ever reached production
      # — disabling a tax soft-deletes the Spree::TaxRate (so Spree's own
      # checkout correctly stops charging it) but leaves the
      # TaxCategoryMapping/TaxMapping rows themselves in place. Without
      # filtering on TaxMapping#enabled, OrderBuilder would still send the
      # disabled tax to Square, which would auto-compute and add it to
      # total_money — charging the customer's EXTERNAL payment for a tax
      # Spree never actually collected.
      before do
        tax_category # materialize it (and the tax as enabled) first
        mapper.map_tax(square_object(id: 'sq_tax_1', type: 'TAX', version: 2,
                                      tax_data: { name: 'Sales Tax', percentage: '8.0', enabled: false, inclusion_type: 'ADDITIVE' }))
      end

      it 'no longer sends that tax to Square at all' do
        built = payload[:line_items].first

        expect(built[:applied_taxes]).to be_nil
        expect(payload[:taxes]).to be_nil
      end
    end
  end

  describe 'a line item whose product has no tax_category (untaxed, matches pre-fix behavior)' do
    it 'includes no applied_taxes on the line item and no order-level taxes array' do
      built = payload[:line_items].first

      expect(built[:applied_taxes]).to be_nil
      expect(payload[:taxes]).to be_nil
    end
  end

  describe 'when the order\'s stock location has no Square location mapped' do
    let(:unmapped_stock_location) { create(:stock_location) }
    let!(:shipment) { create(:shipment, order: order, stock_location: unmapped_stock_location) }

    it 'raises rather than silently pushing to the wrong (or no) location' do
      expect { payload }.to raise_error(/No Square location mapped/)
    end
  end
end
