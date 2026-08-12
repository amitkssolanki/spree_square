module SpreeSquare
  # Mirrors a Square MODIFIER_LIST (e.g. "Choose your sauce"). Modeled
  # separately from Spree's OptionType/Variant system on purpose — Square
  # modifiers are multi-select, per-line-item customizations, not mutually
  # exclusive product variations, and forcing them through OptionType would
  # explode the variant matrix combinatorially.
  class ModifierList < Spree.base_class
    self.table_name = 'spree_square_modifier_lists'

    SINGLE = 'SINGLE'.freeze
    MULTIPLE = 'MULTIPLE'.freeze

    has_many :modifiers, class_name: 'SpreeSquare::Modifier', dependent: :destroy
    has_many :product_modifier_lists, class_name: 'SpreeSquare::ProductModifierList', dependent: :destroy
    has_many :products, class_name: 'Spree::Product', through: :product_modifier_lists

    validates :square_modifier_list_id, presence: true, uniqueness: true
    validates :name, presence: true
    validates :selection_type, inclusion: { in: [SINGLE, MULTIPLE] }

    def multiple? = selection_type == MULTIPLE
  end
end
