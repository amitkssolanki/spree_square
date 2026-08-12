module SpreeSquare
  # Join: which modifier lists apply to which product (a product can have
  # several — e.g. "Choose your sauce" + "Extra toppings").
  class ProductModifierList < Spree.base_class
    self.table_name = 'spree_square_product_modifier_lists'

    belongs_to :product, class_name: 'Spree::Product'
    belongs_to :modifier_list, class_name: 'SpreeSquare::ModifierList'

    validates :modifier_list_id, uniqueness: { scope: :product_id }
  end
end
