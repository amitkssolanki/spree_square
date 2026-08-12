module SpreeSquare
  # A modifier selected on a specific line item, snapshotted at add-to-cart
  # time. The snapshot (not a live reference) is deliberate: a later Square
  # menu edit must never retroactively change what a past order shows or
  # cost.
  class LineItemModifier < Spree.base_class
    self.table_name = 'spree_square_line_item_modifiers'

    belongs_to :line_item, class_name: 'Spree::LineItem'
    belongs_to :modifier, class_name: 'SpreeSquare::Modifier', optional: true

    validates :name_snapshot, presence: true
    validates :price_cents_snapshot, numericality: true

    def self.build_from(modifier)
      new(
        modifier: modifier,
        square_modifier_id: modifier.square_modifier_id,
        name_snapshot: modifier.name,
        price_cents_snapshot: modifier.price_cents
      )
    end
  end
end
