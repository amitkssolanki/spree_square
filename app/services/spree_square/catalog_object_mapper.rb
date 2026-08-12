require 'open-uri'

module SpreeSquare
  # Maps single Square catalog objects (CATEGORY, ITEM, ITEM_VARIATION) onto
  # Spree records. Square is the source of truth for the menu — this is a
  # one-way mirror, never the reverse.
  #
  # `related_objects_by_id` is a lookup (built by CatalogImporter from a
  # SearchCatalogObjects response's `related_objects`) used to resolve
  # references like an item's `category_id` to the full CatalogObjectCategory,
  # or an image id to its CatalogObjectImage.
  class CatalogObjectMapper
    # One shared OptionType for any item that has more than one variation
    # (e.g. sizes). Single-variation items skip this entirely and use the
    # product's master variant — avoids OptionType/OptionValue bookkeeping for
    # the common case, since most menu items don't have real variations.
    VARIATION_OPTION_TYPE_NAME = 'square_variation'.freeze

    def initialize(related_objects_by_id: {})
      @related_objects_by_id = related_objects_by_id
      @store = Spree::Store.default
      @shipping_category = Spree::ShippingCategory.find_by(name: 'Default') || Spree::ShippingCategory.first
      @channel = Spree::Channel.find_by(code: 'online') || Spree::Channel.first
    end

    def map_category(square_object)
      data = square_object.category_data
      name = data.name.presence || 'Uncategorized'
      mapping = SpreeSquare::TaxonMapping.find_or_initialize_by(square_category_id: square_object.id)

      # Square's SearchCatalogObjects index is only eventually consistent —
      # a category deleted and recreated (or, as observed in practice, a
      # stale duplicate momentarily reappearing alongside the fresh one) can
      # surface a second CatalogObject with a different id but the same
      # name before a TaxonMapping exists for it. Category name+store is
      # unique in Spree (see Spree::Category#requires_taxonomy? — no
      # taxonomy, so uniqueness is scoped to store_id), so falling back to
      # an existing same-named category avoids a hard crash on that race
      # instead of trying (and failing) to create a duplicate.
      taxon = mapping.taxon || Spree::Category.find_by(store: @store, name: name) || Spree::Category.new(store: @store)
      taxon.name = name
      taxon.save!

      mapping.taxon = taxon
      mapping.square_version = square_object.version
      mapping.save!

      taxon
    end

    # A Square MODIFIER_LIST embeds its full MODIFIER objects inline (same
    # pattern as ITEM#variations) — no follow-up API call needed.
    def map_modifier_list(square_object)
      data = square_object.modifier_list_data
      list = SpreeSquare::ModifierList.find_or_initialize_by(square_modifier_list_id: square_object.id)
      list.name = data.name.presence || 'Options'
      list.selection_type = data.selection_type.presence || SpreeSquare::ModifierList::SINGLE
      list.min_selected_modifiers = data.min_selected_modifiers
      list.max_selected_modifiers = data.max_selected_modifiers
      list.square_version = square_object.version
      list.save!

      Array(data.modifiers).each { |modifier| map_modifier(modifier, list) }
      list
    end

    def map_modifier(square_object, modifier_list)
      data = square_object.modifier_data
      modifier = SpreeSquare::Modifier.find_or_initialize_by(square_modifier_id: square_object.id)
      modifier.modifier_list = modifier_list
      modifier.name = data.name.presence || 'Option'
      modifier.price_cents = data.price_money&.amount || 0
      modifier.square_version = square_object.version
      modifier.save!
      modifier
    end

    def map_item(square_object)
      data = square_object.item_data
      mapping = SpreeSquare::CatalogMapping.find_or_initialize_by(
        square_catalog_object_id: square_object.id,
        square_object_type: SpreeSquare::CatalogMapping::ITEM
      )
      return mapping.product if mapping.persisted? && mapping.stale?(square_object.version)

      product = mapping.product || Spree::Product.new(
        store: @store,
        shipping_category: @shipping_category,
        status: 'active',
        slug: generate_slug(data.name, square_object.id)
      )
      product.name = data.name.presence || 'Untitled item'
      product.description = data.description
      product.save!

      publish!(product)
      assign_taxons!(product, data)
      assign_modifier_lists!(product, data)

      mapping.product = product
      mapping.square_version = square_object.version
      mapping.last_synced_at = Time.current
      mapping.save!

      Array(data.variations).each { |variation| map_variation(variation, product) }
      import_primary_image(product, data.image_ids&.first) if product.images.empty?

      revalidate!(product)
      product
    end

    def map_variation(square_object, product)
      data = square_object.item_variation_data
      mapping = SpreeSquare::CatalogMapping.find_or_initialize_by(
        square_catalog_object_id: square_object.id,
        square_object_type: SpreeSquare::CatalogMapping::ITEM_VARIATION
      )
      return mapping.variant if mapping.persisted? && mapping.stale?(square_object.version)

      variant = mapping.variant || pick_variant(product, data)
      variant.sku = square_object.id if variant.sku.blank?
      variant.save!

      amount = (data.price_money&.amount || 0) / 100.0
      variant.set_price(data.price_money&.currency || @store.default_currency, amount)

      mapping.variant = variant
      mapping.square_version = square_object.version
      mapping.last_synced_at = Time.current
      mapping.save!

      # A variation's own price/sku change touches the product without
      # firing Spree's product.updated event (see Revalidator) — the
      # storefront's product cache needs telling explicitly either way.
      revalidate!(product)
      variant
    end

    private

    def revalidate!(product)
      SpreeSquare::Revalidator.call(['products', "product:#{product.slug}"])
    end

    # The first variation ever imported for a product reuses its master
    # variant (detected by the master not having a SKU yet — we always set one
    # from the Square variation id). Only the second-and-later variations
    # force creating real (non-master) variants with an option value
    # distinguishing them — Spree requires at least one option value on any
    # non-master variant.
    def pick_variant(product, data)
      return product.master if product.master.sku.blank?

      option_value = find_or_create_option_value(data.name.presence || 'Default')
      variant = product.variants.build
      variant.option_values << option_value
      variant
    end

    def find_or_create_option_value(name)
      option_type = Spree::OptionType.find_or_create_by!(name: VARIATION_OPTION_TYPE_NAME) do |ot|
        ot.presentation = 'Variation'
      end
      option_type.option_values.find_or_create_by!(name: name.parameterize) do |ov|
        ov.presentation = name
      end
    end

    def publish!(product)
      return unless @channel

      product.product_publications.find_or_create_by!(channel: @channel)
    end

    def assign_taxons!(product, item_data)
      category_ids = Array(item_data.category_id) + Array(item_data.categories).map(&:id)
      taxons = category_ids.uniq.filter_map do |square_category_id|
        SpreeSquare::TaxonMapping.find_by(square_category_id: square_category_id)&.taxon
      end
      product.taxons = taxons if taxons.any?
    end

    # Square is master: replace the full set each sync so a modifier list
    # detached from an item in Square disappears here too, not just
    # additions.
    def assign_modifier_lists!(product, item_data)
      list_ids = Array(item_data.modifier_list_info)
                 .reject { |info| info.enabled == false }
                 .map(&:modifier_list_id)

      lists = SpreeSquare::ModifierList.where(square_modifier_list_id: list_ids)
      existing_ids = SpreeSquare::ProductModifierList.where(product_id: product.id).pluck(:modifier_list_id)

      (lists.pluck(:id) - existing_ids).each do |list_id|
        SpreeSquare::ProductModifierList.create!(product: product, modifier_list_id: list_id)
      end
      (existing_ids - lists.pluck(:id)).each do |list_id|
        SpreeSquare::ProductModifierList.where(product_id: product.id, modifier_list_id: list_id).destroy_all
      end
    end

    def import_primary_image(product, image_id)
      return if image_id.blank?

      image_object = @related_objects_by_id[image_id]
      url = image_object&.image_data&.url
      return if url.blank?

      downloaded = URI.parse(url).open
      image = product.master.images.build
      image.attachment.attach(
        io: downloaded,
        filename: "#{product.slug}#{File.extname(URI.parse(url).path.to_s).presence || '.jpg'}",
        content_type: downloaded.content_type
      )
      image.save!
    rescue StandardError => e
      Rails.logger.warn("[SpreeSquare] image import failed for product #{product.id}: #{e.message}")
    end

    def generate_slug(name, square_id)
      base = name.presence || 'item'
      "#{base.parameterize}-#{square_id.downcase}"
    end
  end
end
