# Demo/dev convenience, not shipped in the packaged gem (see spree_square.gemspec's
# `s.files` — this file and demo_menu*/demo_menu_images/ are excluded from `s.files`
# on purpose: they're restaurant-menu-specific example content, not something every
# installer of this extension wants bundled in). Kept in the source repo as a
# reference for how to seed a Square sandbox catalog end to end.
#
# square.rb doesn't require this from its main entrypoint (it's an opt-in
# multipart-upload helper, only needed by tasks that upload files — just this
# one), so it isn't loaded by `require 'square'` alone.
require 'square/file_param'

namespace :spree_square do
  # Demo/dev convenience: populates the configured Square sandbox with a full
  # restaurant menu (categories, items, prices, photos) so there's something
  # real to look at besides the starter's single sample item. Square stays
  # the source of truth even for demo data — this pushes INTO Square, then
  # runs the normal M2 importer to pull it down into Spree, exactly like a
  # real menu edit would flow.
  #
  # Usage:
  #   bin/rails spree_square:seed_demo_menu
  #   CLEAR_CATALOG=true bin/rails spree_square:seed_demo_menu   # wipe the sandbox catalog first
  #
  # Re-running without CLEAR_CATALOG=true creates duplicate items — Square's
  # batch-upsert only updates in place when given a real (non-temporary)
  # object id, and this task always creates fresh ones. Fine for a sandbox;
  # clear first if you want a clean slate.
  desc 'Demo: seed the Square sandbox catalog with a full sample restaurant menu (with photos)'
  task seed_demo_menu: :environment do
    client = SpreeSquare::Client.instance
    menu_path = File.join(__dir__, 'demo_menu.json')
    images_dir = File.join(__dir__, 'demo_menu_images')
    menu = JSON.parse(File.read(menu_path))

    if ActiveModel::Type::Boolean.new.cast(ENV['CLEAR_CATALOG'])
      existing_ids = client.catalog.list(types: 'ITEM,CATEGORY,IMAGE,MODIFIER_LIST,MODIFIER').map(&:id)
      if existing_ids.any?
        existing_ids.each_slice(200) { |slice| client.catalog.batch_delete(object_ids: slice) }
        puts "Cleared #{existing_ids.size} existing catalog object(s)."
        # BatchDeleteCatalogObjects is immediately consistent for direct
        # reads, but the SearchCatalogObjects index (what both this task's
        # own duplicate-check below and CatalogImporter use) lags behind by
        # a few seconds — without this pause, the import at the end of this
        # task can still see the just-deleted objects and create duplicate
        # Spree categories/products before Square's index catches up.
        sleep 5
      end
    end

    objects = []
    menu.each_key do |category_name|
      objects << {
        type: 'CATEGORY',
        id: "#cat-#{category_name.parameterize}",
        category_data: { name: category_name }
      }
    end

    menu.each do |category_name, items|
      items.each do |item|
        item_temp_id = "#item-#{item['image_slug']}"
        objects << {
          type: 'ITEM',
          id: item_temp_id,
          item_data: {
            name: item['name'],
            description: item['description'],
            # `category_id` (singular) is a legacy field this Square API
            # version silently drops on write — verified by round-tripping
            # a test item through upsert and reading it back via search:
            # category_id came back nil every time, `categories` (array)
            # is what actually persists. CatalogObjectMapper#assign_taxons!
            # already reads both, so no mapper change needed.
            categories: [{ id: "#cat-#{category_name.parameterize}" }],
            variations: [
              {
                type: 'ITEM_VARIATION',
                id: "#{item_temp_id}-regular",
                item_variation_data: {
                  name: 'Regular',
                  pricing_type: 'FIXED_PRICING',
                  price_money: { amount: item['price_cents'], currency: 'USD' }
                }
              }
            ]
          }
        }
      end
    end

    puts "Pushing #{menu.values.sum(&:size)} item(s) across #{menu.size} categories to Square..."
    response = client.catalog.batch_upsert(
      idempotency_key: SecureRandom.uuid,
      batches: [{ objects: objects }]
    )
    # `object_id_` (trailing underscore), not `object_id` — the SDK avoids
    # shadowing Ruby's own Object#object_id; `api_name: "object_id"` is just
    # the JSON wire name.
    id_by_temp_id = response.id_mappings.to_h { |m| [m.client_object_id, m.object_id_] }

    puts 'Uploading photos...'
    uploaded = 0
    menu.each_value do |items|
      items.each do |item|
        item_temp_id = "#item-#{item['image_slug']}"
        real_item_id = id_by_temp_id[item_temp_id]
        image_path = File.join(images_dir, "#{item['image_slug']}.jpg")
        unless real_item_id && File.exist?(image_path)
          puts "  skipped #{item['name']} (no #{real_item_id ? 'image file' : 'mapped id'})"
          next
        end

        # `images.create`'s multipart builder writes `request:` verbatim
        # (Square::Internal::Multipart::FormData#add has no Hash case, only
        # String/Integer/Float/Boolean/#read) — an unserialized Hash gets
        # written as Ruby's `Hash#to_s`, not JSON, so the request must be
        # JSON-encoded ourselves first.
        client.catalog.images.create(
          request: {
            idempotency_key: SecureRandom.uuid,
            object_id: real_item_id,
            image: { type: 'IMAGE', id: "#image-#{item['image_slug']}", image_data: { name: "#{item['name']} photo" } },
            is_primary: true
          }.to_json,
          image_file: Square::FileParam.from_filepath(filepath: image_path, content_type: 'image/jpeg')
        )
        uploaded += 1
      end
    end
    puts "Uploaded #{uploaded} photo(s)."

    puts '---'
    puts 'Importing into Spree...'
    # Square's SearchCatalogObjects index lagged the writes above by well
    # over 10s in practice during development of this task — a short pause
    # isn't enough to trust the search results that CatalogImporter relies on.
    sleep 20
    result = SpreeSquare::CatalogImporter.call
    puts "Imported #{result.categories_count} categories and #{result.items_count} item(s) into Spree."
    puts 'If any items are missing, they just need the index to catch up — re-run: bin/rails spree_square:import_catalog'
  end
end
