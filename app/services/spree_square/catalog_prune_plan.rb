module SpreeSquare
  # What a catalog import would REMOVE from Spree, measured before anything
  # is written (2.4.1, OI-195), and the sanity cap that decides whether those
  # removals may go ahead.
  #
  # Read-only: it only counts. SpreePos::CatalogSync does the removing, and
  # only when this plan is within the cap:
  #
  #   * items and variations no longer listed are discontinued (archived,
  #     never deleted) by #prune_missing!;
  #   * options a modifier list no longer offers are removed by
  #     #map_modifier_list (past orders keep their snapshot);
  #   * a category no longer listed is released, and its taxon deleted only
  #     when the connection owns everything in it.
  #
  # The cap exists because every one of those is driven by ABSENCE from a
  # listing, and a listing can be wrong without raising: an empty or
  # truncated 200 from Square, a filter bug, a credential that suddenly
  # reads another merchant's catalog. So if any one kind would lose more
  # than `max_fraction` of what this connection has live (and more than
  # MIN_ABSOLUTE of it, so a small menu can still lose one dish), no removal
  # of any kind is made on this run: additions and changes still apply, the
  # SyncRun records the withheld counts, and an alert names them. A human
  # confirms in Square and, if the change is real, runs the import once with
  # a higher cap (see CatalogImporter).
  #
  # The category count is an upper bound: a category whose taxon also holds
  # something the connection does not own is released rather than deleted.
  class CatalogPrunePlan
    DEFAULT_MAX_FRACTION = 0.25
    MIN_ABSOLUTE = 2
    KINDS = %i[products variants modifiers categories].freeze

    # @param snapshot [SpreePos::Catalog::Snapshot] the COMPLETE listing
    # @param extra_present_ids [Array<String>] ids a second listing pass saw
    #   (CatalogAdapter's paged-listing guard); present if seen by either pass
    def initialize(connection:, snapshot:, extra_present_ids: [], max_fraction: nil)
      @connection = connection
      @snapshot = snapshot
      @extra_present_ids = Array(extra_present_ids)
      @max_fraction = (max_fraction || self.class.configured_max_fraction).to_f
    end

    # SPREE_SQUARE_PRUNE_MAX_FRACTION (non-secret, optional) overrides the
    # default for a deployment; an operator's one-off run passes
    # `max_prune_fraction:` to CatalogImporter instead.
    def self.configured_max_fraction
      value = ENV['SPREE_SQUARE_PRUNE_MAX_FRACTION'].presence
      value ? Float(value) : DEFAULT_MAX_FRACTION
    rescue ArgumentError
      DEFAULT_MAX_FRACTION
    end

    attr_reader :max_fraction

    def seen_item_external_ids
      @seen_item_external_ids ||= (@snapshot.items.map(&:external_id) | @extra_present_ids)
    end

    def seen_variation_external_ids
      @seen_variation_external_ids ||= @snapshot.items.flat_map { |item| Array(item.variations).map(&:external_id) }
                                                .uniq
    end

    def seen_category_external_ids
      @seen_category_external_ids ||= (@snapshot.categories.map(&:external_id) | @extra_present_ids)
    end

    # @return [Hash{Symbol=>Integer}] how many live records each kind would lose
    def removals
      @removals ||= {
        products: gone_live_records(SpreePos::ExternalRef::RESOURCE_ITEM, seen_item_external_ids, :product),
        variants: gone_live_records(SpreePos::ExternalRef::RESOURCE_VARIATION, seen_variation_external_ids, :variant),
        modifiers: gone_modifiers,
        categories: gone_categories
      }
    end

    # @return [Hash{Symbol=>Integer}] how many live records each kind has now
    def baseline
      @baseline ||= {
        products: live_records(SpreePos::ExternalRef::RESOURCE_ITEM, :product).size,
        variants: live_records(SpreePos::ExternalRef::RESOURCE_VARIATION, :variant).size,
        modifiers: modifiers_in_listed_groups.count,
        categories: category_refs.distinct.count(:spree_id)
      }
    end

    # @return [Array<Symbol>] the kinds over the cap
    def over_cap
      KINDS.select do |kind|
        count = removals[kind]
        count > MIN_ABSOLUTE && count > (baseline[kind] * max_fraction)
      end
    end

    def exceeds_cap? = over_cap.any?

    def summary
      KINDS.map { |kind| "#{kind} #{removals[kind]}/#{baseline[kind]}" }.join(', ')
    end

    private

    def refs(resource_type)
      SpreePos::ExternalRef.for_connection(@connection).of_type(resource_type)
    end

    # [external_id, record] for every ref whose Spree record is still on
    # sale: not soft-deleted (the typed reader returns nil), not already
    # discontinued or archived. A record already retired is not a removal.
    def live_records(resource_type, accessor)
      @live_records ||= {}
      @live_records[resource_type] ||= refs(resource_type).to_a.filter_map do |ref|
        record = ref.public_send(accessor)
        next if record.nil? || record.discontinued?
        next if record.respond_to?(:status) && record.status == 'archived'

        [ref.external_id, record]
      end
    end

    # Mirrors SpreePos::CatalogSync#prune_resource!: an empty seen list prunes
    # nothing there, but it is exactly the listing this cap must catch, so
    # here it counts as "everything would go".
    def gone_live_records(resource_type, seen_ids, accessor)
      live_records(resource_type, accessor).count { |external_id, _| !seen_ids.include?(external_id) }
    end

    def listed_groups
      @listed_groups ||= @snapshot.modifier_groups.index_by(&:external_id)
    end

    def modifiers_in_listed_groups
      SpreePos::Modifier.joins(:modifier_list)
                        .where(pos_connection_id: @connection.id,
                               spree_pos_modifier_lists: { pos_connection_id: @connection.id,
                                                           external_id: listed_groups.keys })
    end

    # Mirrors SpreePos::CatalogSync#remove_missing_modifiers!, per listed group.
    def gone_modifiers
      SpreePos::ModifierList.where(pos_connection_id: @connection.id, external_id: listed_groups.keys)
                            .includes(:modifiers).sum do |list|
        group = listed_groups[list.external_id]
        present = Array(group.modifiers).map(&:external_id)
        next 0 if present.empty? && !group.modifiers_complete

        list.modifiers.count { |modifier| !present.include?(modifier.external_id) }
      end
    end

    def category_refs = refs(SpreePos::ExternalRef::RESOURCE_CATEGORY)

    # Taxons only a no-longer-listed category id maps (deleted or released).
    def gone_categories
      kept = category_refs.where(external_id: seen_category_external_ids).pluck(:spree_id)
      (category_refs.where.not(external_id: seen_category_external_ids).pluck(:spree_id).uniq - kept).size
    end
  end
end
