module SpreeSquare
  # Maps a Square Location 1:1 to a Spree::StockLocation. Restaurant branches
  # map onto Spree's existing multi-warehouse StockLocation model —
  # StockItem's per-location inventory tracking is exactly what "86'd at this
  # branch but not that one" needs, for free.
  class LocationMapping < Spree.base_class
    self.table_name = 'spree_square_location_mappings'

    belongs_to :stock_location, class_name: 'Spree::StockLocation', foreign_key: 'spree_stock_location_id'

    validates :square_location_id, presence: true, uniqueness: true
    validates :stock_location, presence: true
  end
end
