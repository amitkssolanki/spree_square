module SpreeSquare
  # Maps a Spree::Order to the Square Order (and its EXTERNAL payment) it was
  # pushed to on completion.
  class OrderMapping < Spree.base_class
    self.table_name = 'spree_square_order_mappings'

    belongs_to :order, class_name: 'Spree::Order', foreign_key: 'spree_order_id'

    validates :order, presence: true, uniqueness: true

    def mark_failed!(error)
      update!(push_error: error.to_s.truncate(2000))
    end
  end
end
