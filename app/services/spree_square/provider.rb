module SpreeSquare
  # Square's implementation of the SpreePos::Provider contract (plan
  # section 8.1) — the object the registry hands back for `:square`, and
  # the single place that binds this gem's five long-standing
  # implementation classes together.
  #
  # This class deliberately contains NO logic of its own. Every method is a
  # one-line binding to a class that already existed and already had specs;
  # introducing the provider is a wiring change, not a behaviour change.
  # If you find yourself wanting to put logic here, it almost certainly
  # belongs in the adapter it would be wrapping.
  #
  # Instantiation: `SpreePos::Provider#initialize` takes a connection, and
  # a nil connection is legitimate today. Order push always has one (it
  # resolves a SpreePos::Location first, and the mapping columns are NOT
  # NULL). The webhook/catalog/inventory paths do not yet, because inbound
  # events are not routed to a connection until onboarding lands
  # (plan Phase 5, section 15.2) — every adapter below resolves its own
  # credentials through SpreeSquare::Client for now, exactly as it did
  # before this class existed. Nothing here reads `connection`; when the
  # webhook paths start resolving one, this is where it gets threaded
  # through.
  class Provider < SpreePos::Provider
    def self.key = :square

    def self.display_name = 'Square'

    # Only what THIS integration actually implements, not everything the
    # Square API is capable of. `supports?` gates real runtime behaviour
    # (see SpreePos::OrderPush's idempotency decision), so declaring a
    # capability we do not honour would be a latent bug rather than
    # documentation.
    #
    # Deliberately NOT declared, though Square's API does support them and
    # the plan's own capability matrix (section 9.1) lists them as Square
    # features: :catalog_location_availability and
    # :catalog_location_pricing. SpreeSquare::CatalogAdapter ignores
    # `present_at_location_ids` and `location_overrides` entirely (plan
    # Q3/Q7, both settled as out of scope), so claiming them here would
    # tell a future caller something untrue about what this adapter does.
    def self.capabilities
      @capabilities ||= Set[
        # mandatory
        :auth,
        :locations,
        :catalog_full_import,
        :order_push,
        :webhook_receive,
        # optional, and genuinely implemented here
        :catalog_versioning,
        :catalog_images,
        :catalog_taxes,
        :modifier_groups,
        :item_variants,
        :inventory_pull,
        :multi_location_per_connection,
        :order_status_push,
        :order_cancel_sync,
        :order_idempotency_key,
        :webhook_hmac_signature,
        :webhook_payload_carries_data,
        :webhook_subscription_api
      ].freeze
    end

    # OAuth lives on the class (authorize_url/exchange_code/refresh/revoke
    # are all `def self.`), so the class itself is the adapter.
    def auth = SpreeSquare::OauthClient

    def locations = SpreeSquare::LocationAdapter.new

    def catalog = SpreeSquare::CatalogAdapter.new

    def orders = SpreeSquare::OrderAdapter.new(connection: connection)

    # Class, not instance: every WebhookAdapter method is `def self.`
    # (verify / signature_header / signing_key / parse /
    # idempotency_key_for / extract_order_status).
    def webhooks = SpreeSquare::WebhookAdapter

    # Guarded by `supports?(:inventory_pull)` on the SpreePos side.
    # An INSTANCE since B2: the adapter needs this provider's connection to
    # scope its SpreePos::ExternalRef lookups. Both entry points (`call`,
    # `reconcile_all!`) exist on the instance.
    def inventory = SpreeSquare::InventoryAdapter.new(connection: connection)
  end
end
