module SpreeSquare
  # Legacy endpoint (plan section 15.5): `POST /spree_square/webhooks/square`
  # is registered with Square today and cannot change without an operator
  # action, so it must keep working forever, unchanged.
  #
  # RETAINED COMPATIBILITY SHIM. It exists only to keep that URL alive, and
  # it deliberately holds no webhook logic of its own — it selects Square
  # explicitly (the URL has always unconditionally meant Square, so there
  # is nothing to read from params) and then runs the exact same
  # provider-neutral verify -> record -> ack -> enqueue path in
  # SpreePos::WebhooksController that `POST /spree_pos/webhooks/square`
  # runs. There is one implementation, not two.
  #
  # Note what changed in Package A: it now goes through the registry
  # (`SpreePos.provider(:square)`) rather than bypassing it. That means the
  # legacy route and the generic route resolve to the same registered
  # provider object, so they cannot drift apart, and a Square registration
  # failure is visible on both rather than silently only on one.
  #
  # Naming `:square` here is the documented compatibility boundary: this
  # file lives in the Square gem, so it is allowed to know it is Square.
  # The provider-neutral controller it subclasses is not.
  class WebhooksController < SpreePos::WebhooksController
    def create
      provider_class = SpreePos.provider(:square)
      handle(provider_class)
    rescue ArgumentError
      # Square's own engine failed to register (a broken boot, or this gem
      # loaded without spree_pos resolving). Fail closed and loudly rather
      # than silently accepting an unverifiable webhook.
      Rails.logger.error('[SpreeSquare] legacy webhook route: :square is not registered with SpreePos')
      head :not_found
    end
  end
end
