module SpreeSquare
  # Temporary compatibility shim -- deleted in a later phase (step 19) once
  # spree_host's admin UI is repointed at SpreePos:: directly. The real
  # model now lives at SpreePos::ProductModifierList; this subclass exists
  # only so spree_host/app/controllers/spree/admin/square_modifier_lists_controller.rb
  # (out of scope this batch) keeps working unchanged.
  #
  # No `type` column exists on spree_pos_product_modifier_lists, so this is
  # plain AR subclassing -- not STI.
  class ProductModifierList < SpreePos::ProductModifierList
  end
end
