RSpec.describe SpreeSquare::SquareSdkFalseValues do
  it 'keeps an explicit false on a declared catalog field, however the object is built' do
    expect(Square::Types::CatalogTax.load({ name: 'Tax', enabled: false }.to_json).enabled).to be(false)
    expect(Square::Types::CatalogItemModifierListInfo.new(modifier_list_id: 'M', enabled: false).enabled).to be(false)
    expect(Square::Types::CatalogObject.coerce({ type: 'TAX', id: 'T', version: 1, tax_data: { enabled: false } })
                                       .tax_data.enabled).to be(false)
  end

  it 'leaves true and absent values exactly as the SDK reads them' do
    expect(Square::Types::CatalogTax.new(enabled: true).enabled).to be(true)
    expect(Square::Types::CatalogTax.new(name: 'Tax').enabled).to be_nil
  end

  it 'is installed on the catalog types this integration reads, and nothing else' do
    expect(described_class.target_classes).to all(satisfy { |klass| klass.name.split('::').last.start_with?('Catalog') })
    expect(Square::Types::CatalogTax.ancestors).to include(described_class)
    expect(Square::Types::Money.ancestors).not_to include(described_class)
    expect(Square::Internal::Types::Model.ancestors).not_to include(described_class)
  end

  it 'installs idempotently' do
    expect { described_class.install! }.not_to(change { Square::Types::CatalogTax.ancestors.count(described_class) })
  end
end
