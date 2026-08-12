# Changelog

All notable changes to this project are documented here.

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
