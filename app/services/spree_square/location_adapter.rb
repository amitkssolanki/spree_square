module SpreeSquare
  # Translates Square's Locations API (ListLocations) into
  # SpreePos::Catalog::Location values — the same provider-neutral DTO shape
  # the Phase 1 provider contract (spree_pos's
  # `lib/spree_pos/testing_support/provider_contract.rb`, "#locations.list")
  # already expects every adapter's `locations.list` to return.
  #
  # Scope note (plan step 15 / section 14.4 / 17): this class is read-only
  # translation. It does NOT create, update, or otherwise touch
  # SpreeSquare::LocationMapping — matching a returned location to a
  # Spree::StockLocation stays a human/admin decision, and building that
  # matching UI is Phase 4's Spree::Admin::PosLocationsController (step 31),
  # not this step. Today there is no existing code path that calls Square's
  # ListLocations at all (LocationMapping rows are created by hand); this
  # adapter exists so that lookup can be done through the same Client
  # abstraction as everything else, in a shape ready for a future admin
  # matching screen or console/rake usage — without inventing any new
  # location-management behavior.
  class LocationAdapter
    def self.list(...) = new(...).list

    def initialize(client: SpreeSquare::Client.instance)
      @client = client
    end

    def list
      response = @client.locations.list
      Array(response.locations).map { |location| to_dto(location) }
    end

    private

    def to_dto(location)
      SpreePos::Catalog::Location.new(
        external_id: location.id,
        name: location.name,
        address: format_address(location.address),
        timezone: location.timezone
      )
    end

    def format_address(address)
      return nil if address.nil?

      [
        address.address_line_1,
        address.locality,
        address.administrative_district_level_1,
        address.postal_code
      ].compact_blank.join(', ').presence
    end
  end
end
