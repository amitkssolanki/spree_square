module SpreeSquare
  # Temporary compatibility shim -- deleted in a later phase (step 19) once
  # spree_host's admin UI is repointed at SpreePos:: directly. The real
  # model now lives at SpreePos::LineItemModifier; this subclass exists only
  # so spree_host/app/controllers/spree/admin/square_modifier_lists_controller.rb
  # (out of scope this batch) keeps working unchanged.
  #
  # No `type` column exists on spree_pos_line_item_modifiers, so this is
  # plain AR subclassing -- not STI.
  class LineItemModifier < SpreePos::LineItemModifier
  end
end
