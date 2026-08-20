Rails.application.config.after_initialize do
  # new_resource: false — read-only support/diagnostic tables (no
  # `:new`/`:create` route exists; only: [:index] in config/routes.rb). The
  # default (true) crashes with a routing error the moment the table is
  # ever empty, because the "no resource found" empty-state partial builds
  # a `new_object_url` link unconditionally unless told not to. Found live
  # via the sibling spree_doordash gem's own admin pages, which hit the
  # same bug and fixed it in spree_admin_doordash_tables.rb.
  Spree.admin.tables.register(:square_order_mappings, model_class: SpreeSquare::OrderMapping,
                                                        search_param: :square_order_id_cont, new_resource: false)

  Spree.admin.tables.square_order_mappings.add :order_number,
    label: :order,
    type: :string,
    sortable: false,
    filterable: false,
    default: true,
    position: 10,
    method: ->(mapping) { mapping.order&.number }

  Spree.admin.tables.square_order_mappings.add :square_order_id,
    label: :square_order_id,
    type: :string,
    sortable: true,
    filterable: true,
    default: true,
    position: 20

  Spree.admin.tables.square_order_mappings.add :last_status,
    label: :status,
    type: :string,
    sortable: true,
    filterable: true,
    default: true,
    position: 30

  Spree.admin.tables.square_order_mappings.add :push_error,
    label: :push_error,
    type: :string,
    sortable: false,
    filterable: false,
    default: true,
    position: 40

  Spree.admin.tables.square_order_mappings.add :created_at,
    label: :created_at,
    type: :datetime,
    sortable: true,
    filterable: false,
    default: true,
    position: 50

  Spree.admin.tables.register(:square_webhook_events, model_class: SpreeSquare::WebhookEvent,
                                                        search_param: :event_type_cont, new_resource: false)

  Spree.admin.tables.square_webhook_events.add :event_type,
    label: :event_type,
    type: :string,
    sortable: true,
    filterable: true,
    default: true,
    position: 10

  Spree.admin.tables.square_webhook_events.add :status,
    label: :status,
    type: :string,
    sortable: true,
    filterable: true,
    default: true,
    position: 20

  Spree.admin.tables.square_webhook_events.add :processed_at,
    label: :processed_at,
    type: :datetime,
    sortable: true,
    filterable: false,
    default: true,
    position: 30

  Spree.admin.tables.square_webhook_events.add :error_message,
    label: :error_message,
    type: :string,
    sortable: false,
    filterable: false,
    default: true,
    position: 40

  Spree.admin.tables.square_webhook_events.add :created_at,
    label: :received_at,
    type: :datetime,
    sortable: true,
    filterable: false,
    default: true,
    position: 50

  # new_resource: false — read-only, same reason as every table above (no
  # :new/:create route; only: [:index] in config/routes.rb).
  Spree.admin.tables.register(:square_tax_rates, model_class: Spree::TaxRate,
                                                   search_param: :name_cont, new_resource: false)

  Spree.admin.tables.square_tax_rates.add :name,
    label: :name,
    type: :string,
    sortable: true,
    filterable: true,
    default: true,
    position: 10

  Spree.admin.tables.square_tax_rates.add :amount_percentage,
    label: :rate,
    type: :string,
    sortable: false,
    filterable: false,
    default: true,
    position: 20,
    method: ->(rate) { "#{rate.amount_percentage}%" }

  Spree.admin.tables.square_tax_rates.add :zone,
    label: :zone,
    type: :string,
    sortable: false,
    filterable: false,
    default: true,
    position: 30,
    method: ->(rate) { rate.zone&.name }

  Spree.admin.tables.square_tax_rates.add :tax_category,
    label: :tax_category,
    type: :string,
    sortable: false,
    filterable: false,
    default: true,
    position: 40,
    method: ->(rate) { rate.tax_category&.name }

  Spree.admin.tables.square_tax_rates.add :updated_at,
    label: :last_synced,
    type: :datetime,
    sortable: true,
    filterable: false,
    default: true,
    position: 50
end
