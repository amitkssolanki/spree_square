Rails.application.config.after_initialize do
  Spree.admin.navigation.sidebar.add :square_order_mappings,
    label: 'Square Orders',
    url: :admin_square_order_mappings_path,
    icon: 'receipt',
    position: 65,
    active: -> { controller_name == 'square_order_mappings' },
    if: -> { can?(:manage, SpreeSquare::OrderMapping) }

  Spree.admin.navigation.sidebar.add :square_webhook_events,
    label: 'Square Webhooks',
    url: :admin_square_webhook_events_path,
    icon: 'webhook',
    position: 66,
    active: -> { controller_name == 'square_webhook_events' },
    if: -> { can?(:manage, SpreeSquare::WebhookEvent) }

  Spree.admin.navigation.sidebar.add :square_oauth,
    label: 'Square Connection',
    url: :admin_square_oauth_path,
    icon: 'plug',
    position: 67,
    active: -> { controller_name == 'square_oauth' },
    if: -> { can?(:manage, SpreeSquare::Credential) }
end
