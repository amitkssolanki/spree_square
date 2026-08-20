namespace :spree_square do
  desc 'M1 verification: list catalog objects from the configured Square sandbox/production account'
  task list_catalog: :environment do
    client = SpreeSquare::Client.instance

    puts "Environment: #{ENV.fetch('SQUARE_ENVIRONMENT', 'sandbox')}"
    puts "Location ID: #{client.location_id}"
    puts '---'

    count = 0
    client.catalog.list(types: 'ITEM,CATEGORY,IMAGE,MODIFIER_LIST,MODIFIER').each do |object|
      count += 1
      # Fern generates one CatalogObject subclass per `type`, and each only
      # defines the data accessor for its own type (e.g.
      # Square::Types::CatalogObjectModifierList has no `item_data` method
      # at all) — `&.` doesn't help against a NoMethodError, so check
      # `respond_to?` first.
      name = %i[item_data category_data modifier_list_data modifier_data image_data]
             .filter_map { |accessor| object.public_send(accessor)&.name if object.respond_to?(accessor) }
             .first || '(unnamed)'
      puts "#{object.type.ljust(14)} #{object.id.ljust(24)} #{name}"
    end

    puts '---'
    puts count.zero? ? 'No catalog objects found — this sandbox account has an empty catalog (expected for a fresh account).' : "#{count} object(s) found."
  end

  desc 'M2: import the full Square catalog (items + categories) into Spree'
  task import_catalog: :environment do
    result = SpreeSquare::CatalogImporter.call
    category_word = result.categories_count == 1 ? 'category' : 'categories'
    puts "Imported #{result.categories_count} #{category_word} and #{result.items_count} item(s)."
    puts '---'
    SpreeSquare::CatalogMapping.where(square_object_type: SpreeSquare::CatalogMapping::ITEM)
                                .includes(:product).find_each do |mapping|
      product = mapping.product
      next unless product

      puts "#{product.slug.ljust(40)} #{product.display_price}"
    end
  end

  # Usage: bin/rails "spree_square:setup_webhook[https://<id>.ngrok-free.app/spree_square/webhooks/square]"
  desc 'M3: create or update the Square webhook subscription for a notification URL'
  task :setup_webhook, [:url] => :environment do |_, args|
    url = args[:url]
    abort 'Usage: bin/rails "spree_square:setup_webhook[https://your-tunnel/spree_square/webhooks/square]"' if url.blank?

    client = SpreeSquare::Client.instance
    event_types = %w[catalog.version.updated inventory.count.updated order.updated order.fulfillment.updated]
    existing = client.webhooks.subscriptions.list.find { |s| s.name == 'spree_square' }

    if existing
      client.webhooks.subscriptions.update(
        subscription_id: existing.id,
        subscription: { notification_url: url, event_types: event_types, enabled: true }
      )
      # `update` doesn't return the signature key (Square only returns it on
      # create/rotate) — fetch a fresh one explicitly so we always have a
      # usable value to put in .env.
      key_response = client.webhooks.subscriptions.update_signature_key(subscription_id: existing.id)
      puts "Updated webhook subscription #{existing.id}"
      puts "Signature key: #{key_response.signature_key}"
    else
      response = client.webhooks.subscriptions.create(
        idempotency_key: SecureRandom.uuid,
        subscription: { name: 'spree_square', notification_url: url, event_types: event_types }
      )
      subscription = response.subscription
      puts "Created webhook subscription #{subscription.id}"
      puts "Signature key: #{subscription.signature_key}"
    end

    puts '---'
    puts 'Set SQUARE_WEBHOOK_SIGNATURE_KEY in .env to the value above, then recreate the web container.'
  end

  desc "Phase 8 M1: ensure a state-scoped tax Zone exists for the store's own StockLocation state"
  task ensure_tax_zone: :environment do
    stock_location = Spree::StockLocation.find_by(default: true)
    abort 'No default Spree::StockLocation found.' if stock_location.blank?

    state = stock_location.state
    abort "StockLocation ##{stock_location.id} (#{stock_location.name}) has no state set — set one before running this task." if state.blank?

    # Named/keyed off the state itself (not hardcoded "OH") and re-derived
    # from StockLocation on every run — if that address ever moves to a
    # different state, re-running this task points the zone at the new one
    # instead of silently leaving a stale zone behind.
    zone = Spree::Zone.find_or_initialize_by(name: "#{state.abbr} Sales Tax")
    zone.kind = 'state'
    zone.description = "Sales tax zone for #{state.name} — tracks Spree::StockLocation's own state; see spree_square:ensure_tax_zone." if zone.has_attribute?(:description)
    zone.save!
    zone.state_ids = [state.id]

    puts "Zone ##{zone.id} '#{zone.name}' now contains exactly: #{zone.states.pluck(:abbr).join(', ')}"
  end

  desc 'Phase 8 M4: create a real 8% Sales Tax object in Square Sandbox, attach it to every item, and tax delivery fees to match'
  task setup_demo_tax: :environment do
    # credential: nil forces the SQUARE_ACCESS_TOKEN env fallback instead of
    # this store's connected OAuth credential — the OAuth connection was
    # authorized without ITEMS_WRITE (confirmed live: its scopes list is
    # MERCHANT_PROFILE_READ/ITEMS_READ/INVENTORY_*/ORDERS_*/PAYMENTS_*, no
    # ITEMS_WRITE), the same scope seed_demo_menu.rake's item-creation
    # calls need. A one-time catalog-admin task like this one reasonably
    # uses the broader sandbox token rather than re-running the OAuth
    # consent flow just to add a scope.
    client = SpreeSquare::Client.new(credential: nil)

    puts 'Creating "Sales Tax" (8.0%) catalog object in Square...'
    response = client.catalog.batch_upsert(
      idempotency_key: SecureRandom.uuid,
      batches: [{
        objects: [{
          type: 'TAX',
          id: '#tax-sales-tax',
          tax_data: {
            name: 'Sales Tax',
            calculation_phase: 'TAX_SUBTOTAL_PHASE',
            inclusion_type: 'ADDITIVE',
            percentage: '8.0',
            applies_to_custom_amounts: true,
            enabled: true
          }
        }]
      }]
    )
    tax_id = response.id_mappings.find { |m| m.client_object_id == '#tax-sales-tax' }&.object_id_
    abort 'Square did not return an id for the new tax object.' if tax_id.blank?
    puts "Created tax #{tax_id}"

    item_ids = client.catalog.search(object_types: ['ITEM']).objects.to_a.map(&:id)
    abort 'No items found in the Square catalog — run spree_square:seed_demo_menu first.' if item_ids.empty?

    puts "Attaching to #{item_ids.size} item(s)..."
    client.catalog.update_item_taxes(item_ids: item_ids, taxes_to_enable: [tax_id])

    puts 'Waiting for Square search index to catch up...'
    sleep 20

    puts 'Importing into Spree...'
    result = SpreeSquare::CatalogImporter.call
    puts "Imported #{result.taxes_count} tax(es) and re-synced #{result.items_count} item(s)."

    tax_mapping = SpreeSquare::TaxMapping.find_by(square_tax_id: tax_id)
    tax_category = tax_mapping&.tax_category_mappings&.first&.tax_category
    if tax_category.blank?
      puts 'Warning: could not resolve the resulting Spree::TaxCategory — did any item actually import with this tax attached?'
    else
      # Square's Catalog API has no concept of a delivery fee at all — this
      # part is Spree-only, applying the same tax category to every
      # shipping method per the confirmed decision (delivery fee taxed the
      # same as food).
      count = Spree::ShippingMethod.update_all(tax_category_id: tax_category.id)
      puts "Set tax_category '#{tax_category.name}' on #{count} shipping method(s): #{Spree::ShippingMethod.pluck(:name).join(', ')}"
    end
  end
end
