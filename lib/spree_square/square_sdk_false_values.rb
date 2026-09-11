require 'square'

module SpreeSquare
  # square.rb 46.x loses every explicit `false` on a DECLARED model field.
  # Square::Internal::Types::Model#initialize reads each field with
  #
  #   values.delete(api_name_symbol) || values.delete(api_name) || values.delete(field_name)
  #
  # so a `false` from the first lookup falls through to lookups that find
  # nothing, and the field ends up nil. A tax or modifier list DISABLED in
  # Square therefore arrived as `enabled: nil`, which cannot be told apart
  # from "not specified", and was imported as enabled.
  #
  # Found on 2026-09-11 when the catalog specs moved from doubles to real SDK
  # objects after the production import failure
  # (docs/b2-cutover-incident-2026-09-11.md in the host repo). square.rb
  # 46.1.0.20260819, the newest release, still has it.
  #
  # The fix puts back exactly what the payload said: once the SDK has built
  # an object, a declared field the payload set to `false` is `false` again.
  # It is scoped to the Catalog* types this integration READS, so requests
  # built from other SDK types are unchanged, and it installs only while the
  # SDK still drops `false`, so a release that fixes the bug makes it a no-op.
  module SquareSdkFalseValues
    def initialize(values = {})
      super
      return unless values.is_a?(::Hash)

      self.class.fields.each do |name, field|
        key = [field.api_name.to_sym, field.api_name.to_s, name, name.to_s].find { |k| values.key?(k) }
        @data[name] = false if key && values[key] == false
      end
    end

    def self.sdk_drops_false?
      Square::Types::CatalogTax.new(enabled: false).enabled.nil?
    end

    def self.target_classes
      Square::Types.constants.grep(/\ACatalog/).filter_map do |name|
        klass = Square::Types.const_get(name)
        klass if klass.is_a?(Class) && klass < Square::Internal::Types::Model
      end
    end

    def self.install!
      return [] unless sdk_drops_false?

      target_classes.each { |klass| klass.prepend(self) unless klass.ancestors.include?(self) }
    end
  end
end

SpreeSquare::SquareSdkFalseValues.install!
