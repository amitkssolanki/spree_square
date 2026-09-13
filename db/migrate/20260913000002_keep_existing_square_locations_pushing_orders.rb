class KeepExistingSquareLocationsPushingOrders < ActiveRecord::Migration[8.1]
  # spree_pos 0.4.0 adds SpreePos::Location#order_push_enabled, an order-push
  # kill switch that defaults to FALSE for every location, existing ones
  # included, because spree_pos cannot vouch for any provider's locations.
  #
  # Square's locations were already pushing orders before the switch existed,
  # and a deploy must not silently stop a live kitchen's tickets. So this
  # enables pushing for the Square locations that exist when it runs, and
  # nothing else:
  #
  # - Square locations only. Every other provider's rows stay exactly as
  #   spree_pos left them, disabled.
  # - Rows that exist now only. A Square location created after this migration
  #   starts disabled like any other and is enabled explicitly.
  #
  # It must run after spree_pos's AddOrderPushActivationToPosLocations. If the
  # column is missing, that migration was not installed or has not run, and
  # continuing would leave this deployment with Square pushes switched off by
  # the next one. So it fails the deploy loudly instead of skipping.
  def up
    return unless table_exists?(:spree_pos_locations)

    unless column_exists?(:spree_pos_locations, :order_push_enabled)
      raise 'spree_pos_locations.order_push_enabled is missing: install and run spree_pos 0.4.0 migrations ' \
            '(bin/rails spree_pos:install:migrations) before this one'
    end

    enabled = exec_update(<<~SQL.squish)
      UPDATE spree_pos_locations
      SET order_push_enabled = #{quoted_true},
          order_push_changed_at = CURRENT_TIMESTAMP,
          order_push_changed_by = 'migration:keep_existing_square_locations_pushing_orders',
          updated_at = CURRENT_TIMESTAMP
      WHERE order_push_enabled = #{quoted_false}
        AND pos_connection_id IN (SELECT id FROM spree_pos_connections WHERE provider = 'square')
    SQL
    say "enabled order pushing on #{enabled} existing Square location(s); no other provider touched", true
  end

  # Nothing to undo that would be safe to guess at: rolling spree_pos back
  # removes the column itself, and switching Square locations off here would
  # stop live order pushes without removing the switch.
  def down; end

  private

  def quoted_true = connection.quoted_true
  def quoted_false = connection.quoted_false
end
