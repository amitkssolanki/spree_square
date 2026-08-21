# Changelog

All notable changes to this project are documented here.

## 0.2.3

Fixes a real bug caught in code review of `v0.2.2` (before it reached production): the new
`OrderBuilder#resolve_square_tax_ids` resolved a product's Square tax id(s) via `TaxCategoryMapping`
with no check on `TaxMapping#enabled`. Disabling a tax in Square soft-deletes the backing
`Spree::TaxRate` (so Spree's own checkout correctly stops charging it) but leaves the
`TaxCategoryMapping`/`TaxMapping` rows themselves in place — so a disabled tax was still resolved,
still sent to Square in `taxes`/`applied_taxes`, and Square would still auto-compute and add it into
`total_money`, meaning `OrderPusher`'s EXTERNAL payment would charge the customer's order for tax
Spree never actually collected. Fixed by filtering to `TaxMapping#enabled` (new regression spec:
disabling a tax via the real `CatalogObjectMapper#map_tax` pipeline and confirming it's excluded).

Also, while already touching this code: memoized Square-tax-id resolution per `tax_category`
instead of re-querying per line item (an order commonly has several line items sharing one
category), and dropped the `SecureRandom.uuid`-per-tax indirection in favor of using each tax's
already-unique `square_tax_id` directly as its `uid` — removes a mutable accumulator hash that had
to be threaded through `build_line_item` for no functional reason.

115 examples (1 new), Brakeman clean.

## 0.2.2

Fixes a real bug found live comparing a completed order's Spree confirmation against its Square
receipt: Spree charged $19.42 including $1.44 tax, but the pushed Square ticket/payment showed a
bare $9.99 with zero tax — every order ever pushed to Square has excluded tax entirely, both from
the visible receipt and from the EXTERNAL payment amount actually recorded (`OrderPusher` records
whatever `square_order.total_money` comes back as, so an untaxed Square order also under-recorded
the real payment total).

Root cause: `OrderBuilder` referenced each line item's `catalog_object_id`, but pointing a Square
order line item at a taxed `CatalogItem` does **not** make Square auto-compute tax on it — Square's
Orders API requires the caller to explicitly build an order-level `taxes` array (one entry per
distinct tax, `scope: 'LINE_ITEM'`, `auto_applied: true`, referencing the tax's own
`catalog_object_id`) and reference it per line item via `applied_taxes: [{tax_uid: ...}]`. This was
never built — a Phase-1-era design decision (deliberately send no tax/discount data, to keep
Square's computed total exactly matching the EXTERNAL payment) made before Phase 8 added any tax
config to sync in the first place, never revisited once it did.

Fixed by resolving each line item's Square tax id(s) via the same `Spree::TaxCategory ->
TaxCategoryMapping -> TaxMapping` path Phase 8's own `CatalogObjectMapper#resolve_tax_category`
already built (walked in reverse), and building the order-level `taxes`/line-item `applied_taxes`
Square actually requires. Delivery/shipping fees are still deliberately not sent to Square (no
shipping line item is pushed at all) — out of scope for this fix, matching an explicit product
decision. 5 new specs (114 total, up from 109), Brakeman clean.

## 0.2.1

Fixes a real bug in `v0.2.0`, found running it against production traffic (not caught by specs —
sandbox/local dev has no registered webhook to race against): the concurrency fix for the composite
tax category race (see `v0.2.0`'s own changelog entry) was itself Postgres-only
(`pg_advisory_xact_lock`), breaking outright on the gem's own SQLite/MySQL-tested dummy app, and
production actually hit the race it was meant to prevent — this rake task's own `CatalogImporter.call`
ran concurrently with a real `catalog.version.updated` webhook Square's own `update_item_taxes` call
fired back mid-run, leaving 44 products correctly on one "Sales Tax" category and 1 stray product on a
duplicate with its own duplicate rate (same 8% amount either way — no wrong tax charged, but a real
data duplication). Replaced with `SpreeSquare::TaxCombination`, a real unique index raced via
`create_or_find_by!` — portable across every adapter this gem supports. `v0.2.0` is yanked; upgrade
directly to this version.

## 0.2.0

- **Sales tax, sourced from Square's own catalog tax config.** Square's Catalog API has no concept
  of jurisdiction, so this is two pieces working together: a new rake task
  (`spree_square:ensure_tax_zone`) sets up a Spree::Zone matching the store's own StockLocation
  state (re-derived live, not hardcoded), and the catalog importer now pulls Square's `TAX`
  catalog objects (`CatalogImporter`/`CatalogObjectMapper#map_tax`) plus each item's `tax_ids`
  (`#resolve_tax_category`), mirroring them into `Spree::TaxRate`/`Spree::TaxCategory` — Spree's
  own built-in tax-calculation engine does the actual per-order math, unchanged. An item carrying
  more than one Square tax at once gets its own composite `Spree::TaxCategory` with one
  `Spree::TaxRate` per constituent tax (`SpreeSquare::TaxMapping`/`TaxCategoryMapping`), rather
  than forcing a single flat rate — correct for the general case, though this project's own
  catalog only ever needs one. Disabling a tax in Square soft-deletes every `Spree::TaxRate` it
  backs; re-enabling restores them. Reuses the existing `catalog.version.updated` webhook — no new
  subscription needed.
- New rake task `spree_square:setup_demo_tax` — creates a real "Sales Tax" object in Square
  Sandbox, batch-attaches it to every item via `update_item_taxes`, and (Spree-side, since Square
  has no concept of a delivery fee at all) applies the same tax category to every shipping method.
- New read-only admin page, "Square Tax Rates" (`/admin/square_tax_rates`), mirroring the existing
  Square Orders/Webhooks pages.
- Fixed a real bug found while building this: `Spree::TaxRate`'s `has_one :calculator, dependent:
  destroy` performs a REAL (hard) destroy even when the owning TaxRate is only soft-deleted —
  acts_as_paranoid only intercepts the TaxRate's own row, not its dependent-destroy callback
  chain. Re-enabling a previously-disabled tax rebuilds the lost calculator explicitly; without
  this, the very next order recalculation against that rate raised
  (`Spree::TaxRate#calculator` was blank).
- Documented, not fixed here (pre-existing, discovered during manual verification): a store's
  connected OAuth credential (`SpreeSquare::Credential`) may not carry `ITEMS_WRITE` if it was
  authorized before this or `seed_demo_menu`'s scope needs existed — both item-write rake tasks
  need it. Reconnecting via the admin's OAuth flow picks up the current scope list; until then,
  `setup_demo_tax` explicitly bypasses the connected credential in favor of `SQUARE_ACCESS_TOKEN`.

## 0.1.3

- New demo menu content: a "Pizzas" category with 5 standalone pizzas plus a
  Build-Your-Own Half & Half Pizza (two stacked SINGLE-select modifier lists,
  "Left Half"/"Right Half", sharing the same 5 toppings) — the concrete
  real-world case for two independent modifier lists stacked on one item.
  Also 2 new combo items (Burger Combo, Family Feast Combo), joining the
  existing Lunch Combo. Demo menu is now 45 items across 8 categories (up
  from 37/7).

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
