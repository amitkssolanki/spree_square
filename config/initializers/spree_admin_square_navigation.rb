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

  # Position 75 — confirmed free at the time this was added by checking
  # every nav initializer across this project: spree_square itself (65-67,
  # above), spree_doordash (68-70), spree_menu_chat (71-72), spree_loyalty
  # (73-74), plus spree_host's own host-local
  # admin_square_modifier_lists_navigation.rb (73 — a pre-existing
  # collision with spree_loyalty's 73, not this extension's to fix).
  # Confirm the actual current highest position the same way before adding
  # another nav item anywhere in this project.
  Spree.admin.navigation.sidebar.add :square_tax_rates,
    label: 'Square Tax Rates',
    url: :admin_square_tax_rates_path,
    icon: 'percentage',
    position: 75,
    active: -> { controller_name == 'square_tax_rates' },
    if: -> { can?(:manage, Spree::TaxRate) }
end
