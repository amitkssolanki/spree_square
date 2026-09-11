require 'square'

# Builds REAL square.rb catalog objects for specs, never doubles.
#
# On 2026-09-11 the first production catalog import under spree_square
# 2.0.0 raised NoMethodError reading `present_at_location_ids` from
# Square::Types::CatalogItem, a field square.rb 46.x declares only on the
# outer catalog object (docs/b2-cutover-incident-2026-09-11.md in the host
# repo). Every spec had passed, because catalog objects were doubles over
# OpenStruct payloads, and those answer any method.
#
# This goes through the SDK's own union coercion and REFUSES a key the SDK
# does not declare for that type, so a spec cannot describe a shape Square
# never sends.
module SquareCatalogObjects
  DATA_TYPES = {
    'ITEM' => [:item_data, Square::Types::CatalogItem],
    'ITEM_VARIATION' => [:item_variation_data, Square::Types::CatalogItemVariation],
    'CATEGORY' => [:category_data, Square::Types::CatalogCategory],
    'TAX' => [:tax_data, Square::Types::CatalogTax],
    'MODIFIER_LIST' => [:modifier_list_data, Square::Types::CatalogModifierList],
    'MODIFIER' => [:modifier_data, Square::Types::CatalogModifier],
    'IMAGE' => [:image_data, Square::Types::CatalogImage]
  }.freeze

  def square_catalog_object(id:, type:, version: 1, **attrs)
    data_key, data_type = DATA_TYPES.fetch(type)
    data = attrs.delete(data_key) || {}

    undeclared = data.keys.map(&:to_sym) - data_type.fields.keys
    raise ArgumentError, "#{data_type.name} does not declare #{undeclared.join(', ')}" if undeclared.any?

    outer_undeclared = attrs.keys.map(&:to_sym) - Square::Types::CatalogObjectBase.fields.keys
    raise ArgumentError, "a Square catalog object does not declare #{outer_undeclared.join(', ')}" if outer_undeclared.any?

    Square::Types::CatalogObject.coerce({ type: type, id: id, version: version, data_key => data, **attrs })
  end
end

RSpec.configure { |config| config.include SquareCatalogObjects }
