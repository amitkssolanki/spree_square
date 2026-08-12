Spree::Core::Engine.add_routes do
  # `isolate_namespace Spree` in the engine means a normal `namespace
  # :spree_square do ... end` block would resolve controllers as
  # `Spree::SpreeSquare::...` (the isolated module gets prepended). The
  # leading `/` on the controller path makes it absolute, resolving to the
  # actual `SpreeSquare::WebhooksController` while keeping the URL prefix.
  post 'spree_square/webhooks/square', to: '/spree_square/webhooks#create'

  # M8: admin support/diagnostic pages — read-only, hence :index only.
  # Plain `namespace :admin` here (unlike the webhook route above) resolves
  # correctly with no path override needed: Spree::Admin::* is the isolated
  # namespace's own convention, not a mismatch like spree_square/ was.
  namespace :admin do
    resources :square_order_mappings, only: [:index]
    resources :square_webhook_events, only: [:index]

    # Self-service OAuth connection (see Spree::Admin::SquareOauthController).
    # Explicit named routes rather than `resource :square_oauth` — the
    # callback is a third, non-CRUD GET action Square itself redirects to.
    get 'square_oauth' => 'square_oauth#show', as: :square_oauth
    get 'square_oauth/connect' => 'square_oauth#connect', as: :connect_square_oauth
    get 'square_oauth/callback' => 'square_oauth#callback', as: :callback_square_oauth
    delete 'square_oauth' => 'square_oauth#destroy', as: :disconnect_square_oauth
  end
end
