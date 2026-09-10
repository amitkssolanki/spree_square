module SpreeSquare
  # Legacy endpoint (plan section 15.5): `POST /spree_square/webhooks/square`
  # is registered with Square today and cannot change without an operator
  # action, so it must keep working forever, unchanged.
  #
  # Unlike SpreePos::WebhooksController#create, this never consults the
  # SpreePos provider registry — the URL itself has always unconditionally
  # meant Square, so there is nothing to look up — it just calls the exact
  # same verify -> record -> enqueue path (#handle_square) that
  # `POST /spree_pos/webhooks/square` uses.
  class WebhooksController < SpreePos::WebhooksController
    def create
      handle_square
    end
  end
end
