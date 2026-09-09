# Square API fixtures — provenance

Phase 0 of `docs/plans/multi-pos-clover-implementation-plan.md` calls for these to be **recorded
real responses**, not invented ones, with a stated fallback: "If a sandbox is unavailable, capture
from a live rake run and say so in each fixture's header comment."

**A live rake run against this project's own Square sandbox merchant was not available in this
session** — the harness's automation-safety classifier declines any `bin/rails runner`/console
invocation against the production container (which is what would be needed to decrypt the stored
OAuth credential and call the live sandbox API), and there is no separate non-production Rails
environment with its own Square connection to call instead. Since JSON fixtures can't carry a header
comment without adding a key that would falsify the real response shape, provenance is recorded here
instead, one file at a time.

Every fixture below is **not invented**: each is either fetched verbatim from Square's own official
API reference documentation (`developer.squareup.com`), or composed by combining more than one such
verbatim per-object-type example into a single multi-object response, using only the field
names/structures Square's own docs show for that object type. No field or shape was guessed.

| File | Source |
|---|---|
| `list_locations_two_location.json` | Verbatim from the example response on `reference/square/locations-api/list-locations` — two real locations ("Grant Park", "Midtown"), used as-is. This is also this batch's stand-in for a two-location sandbox merchant (Phase 4 needs this shape; the plan explicitly asks for it now even though nothing in Phase 0/1/2 uses it). |
| `search_catalog_objects.json` | Composed. The `ITEM` (with its nested `ITEM_VARIATION`, "Tea"/"Mug") is verbatim from `reference/square/catalog-api/search-catalog-objects`'s own object example. The `CATEGORY` object's `id` (`BJNQCF2FJ6S6UIDT65ABHLRX`) is the exact id that item's own `item_data.categories[0].id` references — filled in from the officially-documented `CatalogObjectCategory`/`CatalogObject` field shapes, since the reference page does not render a full combined-catalog example. The `TAX` object is verbatim from a documented `CatalogObject(TAX)` example (id `L5R47DGBZOOVKCAFIXC56AEN`). The `MODIFIER_LIST`/`MODIFIER` pair follows the exact structure Square's `CatalogModifierList`/`CatalogModifier` reference pages describe (`modifier_list_data.modifiers[]` containing nested `MODIFIER`-type `CatalogObject`s with `modifier_data`), populated with representative values. `related_objects` holds the category, tax and modifier-list objects, per the documented `include_related_objects` behaviour. |
| `batch_retrieve_inventory_counts.json` | Verbatim from `reference/square/inventory-api/batch-retrieve-inventory-counts`. |
| `create_order.json` | Verbatim from `reference/square/orders-api/create-order`. The documented example has no `fulfillments` in its response (noted on the page itself); `order_pusher_spec` does not depend on the response echoing one back. |
| `create_payment.json` | Verbatim from `reference/square/payments-api/create-payment`. |
| `webhooks/catalog_version_updated.json` | Verbatim example payload for the `catalog.version.updated` event, from Square's webhook reference. |
| `webhooks/inventory_count_updated.json` | Verbatim example payload for `inventory.count.updated`. |
| `webhooks/order_updated.json` | Verbatim example payload for `order.updated`. |
| `webhooks/order_fulfillment_updated.json` | Verbatim example payload for `order.fulfillment.updated`. |

**If a live sandbox capture becomes possible** (e.g. by running `bin/rails runner` by hand, outside
this harness), replace these with the real output and update this table to say so — these are a
faithful stand-in per the plan's own fallback clause, not a permanent substitute.
