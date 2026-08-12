Rails.application.config.after_initialize do
  Spree.admin.tables.register(:square_order_mappings, model_class: SpreeSquare::OrderMapping, search_param: :square_order_id_cont)

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

  Spree.admin.tables.register(:square_webhook_events, model_class: SpreeSquare::WebhookEvent, search_param: :event_type_cont)

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
end
