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

    # Upserts a Square CatalogTax into SpreeSquare::TaxMapping — a pure
    # mirror (percentage/inclusion/enabled), category-agnostic. Which
    # Spree::TaxCategory (and therefore Spree::TaxRate) this tax actually
    # backs is resolved per-item in map_item, since that depends on which
    # *combination* of taxes each item carries — see resolve_tax_category.
    def map_tax(square_object)
      data = square_object.tax_data
      mapping = SpreeSquare::TaxMapping.find_or_initialize_by(square_tax_id: square_object.id)
      return mapping if mapping.persisted? && mapping.stale?(square_object.version)

      was_enabled = mapping.persisted? ? mapping.enabled : nil
      mapping.name = data.name.presence || 'Square Tax'
      mapping.percentage = data.percentage.presence&.to_d || 0
      mapping.included_in_price = (data.inclusion_type == 'INCLUSIVE')
      mapping.enabled = data.enabled != false
      mapping.square_version = square_object.version
      mapping.last_synced_at = Time.current
      mapping.save!

      # Enable/disable first — a re-enable rebuilds the rate's calculator
      # (see sync_enabled_state!'s own comment for why that's needed), which
      # the amount/inclusion sync below depends on being present.
      sync_enabled_state!(mapping, was_enabled)

      # Already-materialized (and currently live) rates mirror any
      # percentage/inclusion/name change immediately — Square is the source
      # of truth here, these rows are never hand-edited in Spree. A rate
      # that's still disabled is skipped: no live TaxRate exists for it to
      # update, and the next enable will rebuild it fresh from this mapping
      # anyway.
      mapping.tax_category_mappings.includes(:tax_rate).each do |tcm|
        rate = tcm.tax_rate
        next unless rate && !rate.paranoia_destroyed?

        rate.update!(amount: mapping.percentage / 100.0, included_in_price: mapping.included_in_price, name: mapping.name)
      end

      mapping
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
      product.tax_category = resolve_tax_category(data)
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

    # Enable/disable is the one thing that can't just be "update the row" —
    # a disabled Square tax must stop applying everywhere it appears, and a
    # re-enabled one must resume applying with no re-import of the items
    # that reference it. Spree::TaxRate is acts_as_paranoid, so soft-delete/
    # restore is exactly "stop/resume applying" — Spree's own
    # TaxRate.potential_rates_for_zone already excludes deleted rows via its
    # default scope, no other code needs to know about this.
    def sync_enabled_state!(mapping, was_enabled)
      return if was_enabled == mapping.enabled

      mapping.tax_category_mappings.each do |tcm|
        rate = tcm.tax_rate
        next unless rate

        if mapping.enabled
          next unless rate.paranoia_destroyed?

          rate.restore(recursive: true)
          # Spree::TaxRate's `has_one :calculator, dependent: :destroy` is a
          # REAL (hard) destroy even when the owning TaxRate is only
          # soft-deleted — acts_as_paranoid intercepts the TaxRate's own row,
          # not its dependent-destroy callbacks. So a restored rate has no
          # calculator left to restore; rebuild it, or `TaxRate.adjust`'s
          # `delegate :compute, to: :calculator` raises on the next order
          # recalculation.
          rate.calculator_type = 'Spree::Calculator::DefaultTax' if rate.calculator.nil?
          rate.save!
        elsif !rate.paranoia_destroyed?
          rate.destroy
        end
      end
    end

    # Resolves an item's exact set of Square tax_ids to the Spree::TaxCategory
    # that represents that combination — creating it (and the underlying
    # Spree::TaxRate(s), one per constituent Square tax) the first time this
    # exact combination is seen. See TaxCategoryMapping for why a composite
    # category can need more than one row here.
    def resolve_tax_category(item_data)
      square_tax_ids = Array(item_data.tax_ids)
      return non_taxable_category if square_tax_ids.empty?

      tax_mappings = SpreeSquare::TaxMapping.where(square_tax_id: square_tax_ids).to_a
      # Item references a tax id this store hasn't synced yet (import order,
      # or the tax was deleted in Square) — fall back to non-taxable rather
      # than guessing; a later re-import (taxes always run before items)
      # will resolve it correctly once the tax itself is known.
      return non_taxable_category if tax_mappings.empty?

      category = composite_tax_category(tax_mappings)
      ensure_tax_rates!(category, tax_mappings)
      category
    end

    # A real bug found running this against production: the same catalog
    # import can run concurrently more than once (this rake task's own
    # `CatalogImporter.call` racing a real `catalog.version.updated`
    # webhook that Square's own `update_item_taxes` call fires back mid-run
    # — sandbox/local dev, with no registered webhook, never exercises
    # this). Two processes each finding "no matching category yet" and
    # independently creating one left two "Sales Tax" categories with
    # duplicate rates. `SpreeSquare::TaxCombination#signature` is a real
    # unique index — `create_or_find_by!` races against it exactly the way
    # Rails intends (portable across Postgres/MySQL/SQLite, unlike a
    # database-specific advisory lock): the losing side's block-created
    # Spree::TaxCategory rolls back with it (create_or_find_by! wraps the
    # attempt in its own transaction) and it transparently re-finds what
    # the winner created instead.
    def composite_tax_category(tax_mappings)
      signature = SpreeSquare::TaxCombination.signature_for(tax_mappings.map(&:id))

      # `create_or_find_by!`'s block runs while *building* the record, before
      # the create attempt that its own race-safety depends on — so it can
      # run more than once even with no real race at all (confirmed live: a
      # second, non-concurrent call in the same process re-runs this block
      # and only then discovers the TaxCombination already exists). The
      # block itself must therefore be safe to run repeatedly — plain
      # `Spree::TaxCategory.create!` isn't, since core validates `name`
      # uniqueness and a second run raises `RecordInvalid` before this
      # method's own race-safety ever gets a chance to matter.
      combination = SpreeSquare::TaxCombination.create_or_find_by!(signature: signature) do |c|
        name = tax_mappings.map(&:name).join(' + ').presence || 'Square Tax'
        c.tax_category = Spree::TaxCategory.find_by(name: name) || Spree::TaxCategory.create!(name: name)
      end

      combination.tax_category
    end

    def ensure_tax_rates!(category, tax_mappings)
      zone = tax_zone!

      tax_mappings.each do |tm|
        next if SpreeSquare::TaxCategoryMapping.exists?(tax_category_id: category.id, tax_mapping_id: tm.id)

        rate = Spree::TaxRate.create!(
          zone: zone,
          tax_category: category,
          name: tm.name,
          amount: (tm.percentage || 0) / 100.0,
          included_in_price: tm.included_in_price,
          calculator_type: 'Spree::Calculator::DefaultTax'
        )
        SpreeSquare::TaxCategoryMapping.create!(tax_category: category, tax_mapping: tm, tax_rate: rate)
      rescue ActiveRecord::RecordNotUnique
        # A concurrent import created this exact (category, tax) row first
        # (same class of race `composite_tax_category` guards against, just
        # a narrower window) — the orphaned rate this attempt already
        # created never got a join row and is safe to drop; the other
        # side's row is what matters.
        rate&.destroy
      end
    end

    def non_taxable_category
      @non_taxable_category ||= Spree::TaxCategory.find_by(name: 'Non-taxable') ||
                                 Spree::TaxCategory.create!(name: 'Non-taxable')
    end

    # The store's own tax Zone, set up once via `spree_square:ensure_tax_zone`
    # (Square's Catalog API has no jurisdiction concept to sync — this is
    # entirely Spree-side). Raises rather than silently skipping: importing
    # a real tax with no zone to attach it to is a setup error, not a
    # recoverable no-op.
    def tax_zone!
      @tax_zone ||= begin
        state = Spree::StockLocation.find_by(default: true)&.state
        zone = state && Spree::Zone.where(kind: 'state')
                                    .joins(:zone_members)
                                    .where(spree_zone_members: { zoneable_type: 'Spree::State', zoneable_id: state.id })
                                    .first
        raise "No tax Zone found for the store's state — run `bin/rails spree_square:ensure_tax_zone` first." if zone.blank?

        zone
      end
    end
  end
end
