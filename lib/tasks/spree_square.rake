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
end
