module SpreeSquare
  # Mirrors a single Square MODIFIER (e.g. "Extra cheese", +$1.50).
  class Modifier < Spree.base_class
    self.table_name = 'spree_square_modifiers'

    belongs_to :modifier_list, class_name: 'SpreeSquare::ModifierList'

    validates :square_modifier_id, presence: true, uniqueness: true
    validates :name, presence: true
    validates :price_cents, numericality: { greater_than_or_equal_to: 0 }

    def price = price_cents / 100.0
  end
end
