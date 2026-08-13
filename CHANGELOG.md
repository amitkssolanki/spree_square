# Changelog

All notable changes to this project are documented here.

## 0.1.2

- Two new demo menu items (a build-your-own bowl with stacked modifier lists, a combo meal with
  entree/drink/side) with real Square modifier lists — the first end-to-end proof the modifier
  system renders against real Square catalog data, not just specs.
- Fixed a real bug: removing a modifier-bearing line item from the cart raised a foreign-key
  violation (`spree_square_line_item_modifiers` had no `dependent: :destroy`).
- Fixed a real bug: the Square Orders / Square Webhooks admin pages 500'd
  (`undefined method 'new_admin_square_order_mapping_url'`) the moment either table was empty —
  `Spree.admin.tables.register` defaults to expecting a `:new` route that doesn't exist on these
  read-only, index-only resources. Added `new_resource: false` to both.
- Fixed a real bug: installing on MySQL couldn't even run migrations — MySQL rejects a literal
  `DEFAULT` value on `JSON`/`TEXT`/`BLOB` columns outright, which canceled every migration after
  `CreateSpreeSquareWebhookEvents`/`CreateSpreeSquareCredentials` in migration order. Moved both
  defaults (`WebhookEvent#payload`, `Credential#scopes`) to the model layer instead, verified
  against a real MySQL 8.0 database.
- Fixed a Brakeman warning: `WebhooksController` never actually had `protect_from_forgery`
  configured (it doesn't inherit the host app's `ApplicationController`). Added it explicitly
  with `:null_session` — correct for a signature-verified webhook endpoint with no session to
  protect; `:exception` would break every real webhook delivery.

## 0.1.1

- OAuth now requests `PAYMENTS_READ` in addition to the existing scopes. Without it, reading
  payment/refund state (`Client#payments`/raw `refunds` calls) fails with `INSUFFICIENT_SCOPES`
  even though creating payments (`PAYMENTS_WRITE`) already worked. Existing connections need a
  disconnect/reconnect in the admin to pick up the wider grant — Square doesn't expand scopes on
  a token in place.

## 0.1.0

Initial public release.

- Square catalog sync (items, variations, categories, images, modifier lists) into Spree, via a
  full importer and real-time webhooks (`catalog.version.updated`, `inventory.count.updated`).
- Order push: completed Spree orders are pushed into Square as paid tickets (`EXTERNAL` payment),
  targeting the Square location mapped from the order's stock location.
- Order status sync-back: `order.updated` / `order.fulfillment.updated` webhooks keep the Spree
  order's shipment/cancellation state in sync with Square.
- Self-service OAuth ("Connect to Square" in the admin) alongside a hand-issued
  `SQUARE_ACCESS_TOKEN` for local development — see the README's "Connecting to Square" section.
- Nightly reconciliation job, dead-letter alerting on failed order pushes, and admin pages listing
  order mappings and webhook events for support visibility.
