# THE test the whole Package A exists to make true.
#
# Everything else about the registry can be proven with a fake provider,
# and in spree_pos's own suite it is. What a fake can never prove is that
# Square is ACTUALLY registered when a real application boots — which was
# precisely the gap before this change: `SpreePos::Provider` and the
# registry were strict and correct, and `SpreePos.providers` was
# nonetheless `{}` in production, because nothing ever called `.register`
# outside specs.
#
# So: nothing in this file registers anything. It asserts the state the
# dummy application arrived in on its own, through
# SpreeSquare::Engine.activate's `to_prepare` hook. If that hook were
# removed, renamed, or ran too early to autoload the constant, every
# example here fails.
RSpec.describe 'Square provider registration (real application boot)' do
  describe 'the registry, as the booted app left it' do
    it 'has :square registered without any spec having registered it' do
      expect(SpreePos.providers).to have_key(:square)
    end

    it 'resolves :square to the real SpreeSquare::Provider' do
      expect(SpreePos.provider(:square)).to eq(SpreeSquare::Provider)
    end

    it 'resolves the string form too, which is what a webhook URL and a Connection column both carry' do
      expect(SpreePos.provider('square')).to eq(SpreeSquare::Provider)
    end

    it 'registered a genuine provider, not a placeholder that raises on use' do
      # The placeholder this replaced (FakeSquareProviderForWebhookRouting)
      # raised NotImplementedError from all five adapters. A regression to
      # anything like it would pass a naive "is :square registered?" check
      # and fail here.
      #
      # The client stub is needed because two of the adapters
      # (LocationAdapter, CatalogAdapter) resolve credentials eagerly in
      # their default argument (`client: SpreeSquare::Client.instance`), so
      # merely CONSTRUCTING them reaches for a token. That is pre-existing
      # behaviour, not something the provider introduced, but it is worth
      # knowing: `provider.locations` is not free.
      allow(SpreeSquare::Client).to receive(:instance).and_return(instance_double(SpreeSquare::Client))

      provider = SpreePos.provider(:square).new(nil)

      SpreePos::MANDATORY_ADAPTER_METHODS.each do |adapter_method|
        expect { provider.public_send(adapter_method) }.not_to raise_error
        expect(provider.public_send(adapter_method)).not_to be_nil
      end
    end
  end

  describe 'runtime dispatch obtains the registered provider' do
    it 'reaches Square through SpreePos.for_connection, from a real Connection row' do
      connection = create(:pos_connection, provider: 'square')

      expect(SpreePos.for_connection(connection)).to be_a(SpreeSquare::Provider)
    end

    it 'reaches Square through SpreePos.for_location, from a real stock location' do
      pos_location = create(:pos_location, pos_connection: create(:pos_connection, provider: 'square'))

      expect(SpreePos.for_location(pos_location.stock_location)).to be_a(SpreeSquare::Provider)
    end
  end

  describe 'registration is idempotent' do
    it 'survives the to_prepare hook running again, as it does on every dev reload' do
      expect { SpreeSquare::Engine.register_pos_provider! }.not_to raise_error
      expect(SpreePos.provider(:square)).to eq(SpreeSquare::Provider)
    end
  end

  describe 'the registry stays strict' do
    it 'still refuses a provider that does not implement the whole contract' do
      incomplete = Class.new(SpreePos::Provider) do
        def self.key = :incomplete_square_like
        def self.display_name = 'Incomplete'
        def self.capabilities = SpreePos::Capability::MANDATORY

        def auth      = SpreeSquare::OauthClient
        def locations = SpreeSquare::LocationAdapter.new
        def catalog   = SpreeSquare::CatalogAdapter.new
        def orders    = SpreeSquare::OrderAdapter.new
        # deliberately never overrides #webhooks
      end

      expect { SpreePos.register(incomplete) }.to raise_error(SpreePos::UnregisterableProviderError, /webhooks/)
    ensure
      SpreePos.providers.delete(:incomplete_square_like)
    end

    it 'still refuses a provider declaring a capability outside the closed vocabulary' do
      bogus = Class.new(SpreeSquare::Provider) do
        def self.key = :bogus_square_like
        def self.display_name = 'Bogus'
        def self.capabilities = SpreePos::Capability::MANDATORY + Set[:teleportation]
      end

      expect { SpreePos.register(bogus) }.to raise_error(SpreePos::UnregisterableProviderError, /teleportation/)
    ensure
      SpreePos.providers.delete(:bogus_square_like)
    end
  end
end
