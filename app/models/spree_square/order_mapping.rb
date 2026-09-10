module SpreeSquare
  # Temporary compatibility shim -- deleted in a later phase (step 19) once
  # spree_host's admin UI is repointed at SpreePos:: directly. The real
  # model now lives at SpreePos::OrderMapping (Phase 2D, step 16); this
  # subclass exists only so remaining callers by this constant name --
  # square_sync_health.rb (MCP tool, out of scope this batch), the
  # SquareOrderMappingsController/SquareTaxRatesController admin views (also
  # out of scope, admin/table-initializer territory) -- keep working
  # unchanged.
  #
  # No `type` column exists on spree_pos_order_mappings, so this is plain AR
  # subclassing (shares the parent's table via inherited `table_name`) --
  # not STI. Column names changed under it (square_order_id ->
  # external_order_id, etc. -- see the rename migration's own comment); any
  # remaining caller reading the OLD column names by string (e.g. an admin
  # table config) will need updating separately, tracked as out-of-scope
  # sibling work.
  class OrderMapping < SpreePos::OrderMapping
  end
end
