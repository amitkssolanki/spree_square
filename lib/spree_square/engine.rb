module SpreeSquare
  class Engine < Rails::Engine
    require 'spree/core'
    isolate_namespace Spree
    engine_name 'spree_square'

    config.generators do |g|
      g.test_framework :rspec
    end

    initializer 'spree_square.environment', before: :load_config_initializers do |_app|
      SpreeSquare::Config = SpreeSquare::Configuration.new
    end

    # Must run before Active Record's own "active_record_encryption.configuration"
    # initializer reads config.active_record.encryption — a plain
    # config/initializers/*.rb file is too late (that initializer already
    # ran by the time :load_config_initializers fires) and fails silently
    # into "Missing Active Record encryption credential" the first time
    # SpreeSquare::Credential#access_token is touched. ENV, not
    # config/credentials.yml.enc, for the same reason as everything else in
    # this app: spree_host has no credentials.yml.enc, only .env. Living
    # here (not spree_host) means the dummy test app gets it too, via its
    # own spec/.env (see spec/spec_helper.rb's `dotenv/load`).
    initializer 'spree_square.active_record_encryption', before: 'active_record_encryption.configuration' do |app|
      next if ENV['ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY'].blank?

      app.config.active_record.encryption.primary_key = ENV['ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY']
      app.config.active_record.encryption.deterministic_key = ENV['ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY']
      app.config.active_record.encryption.key_derivation_salt = ENV['ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT']
    end

    initializer 'spree_square.assets' do |app|
      if app.config.respond_to?(:assets)
        app.config.assets.paths << root.join('app/javascript')
        app.config.assets.precompile += %w[spree_square_manifest]
      end
    end

    initializer 'spree_square.importmap', before: 'importmap' do |app|
      if app.config.respond_to?(:importmap)
        app.config.importmap.paths << root.join('config/importmap.rb')
        # https://github.com/rails/importmap-rails?tab=readme-ov-file#sweeping-the-cache-in-development-and-test
        app.config.importmap.cache_sweepers << root.join('app/javascript')
      end
    end

    # Decorator files (app/models/spree/*_decorator.rb) intentionally define
    # a constant Zeitwerk maps to their path (e.g. Spree::LineItemDecorator)
    # rather than something under the SpreeSquare:: namespace — but with
    # eager_load off in development, nothing ever references that exact
    # constant name, so lazy autoloading never triggers it and the
    # `SomeClass.prepend(...)` line at the bottom of the file never runs.
    # spree_core's own engine force-loads *its* decorators the same way
    # (lib/spree/core/engine.rb) — each engine has to do this for its own
    # app/ tree; there's no shared mechanism that covers extensions too.
    def self.activate
      Dir.glob(File.join(File.dirname(__FILE__), '../../app/**/*_decorator*.rb')) do |c|
        Rails.application.config.cache_classes ? require(c) : load(c)
      end

      register_pos_provider!
    end

    # Registers Square with the SpreePos registry on every real boot — not
    # only in specs, which is what made the whole provider indirection
    # inert before this change (`SpreePos.providers` was literally `{}` in
    # production).
    #
    # Why here, inside `activate`/`to_prepare`, and not in an
    # `initializer` block:
    #
    #   * `SpreeSquare::Provider` is an autoloaded constant under this
    #     engine's own `app/services`. Referencing an autoloadable
    #     constant from an `initializer` runs before the autoloaders are
    #     set up and raises (or, worse, permanently caches a class that a
    #     later reload replaces). `to_prepare` runs after autoloading is
    #     ready, which is exactly the constraint the decorator force-load
    #     above already lives under.
    #   * `to_prepare` re-runs on every reload in development. That is a
    #     feature here, not a hazard: after a reload `SpreeSquare::Provider`
    #     is a brand-new Class object, and re-registering replaces the
    #     stale one. A registry populated once at boot would hand out an
    #     unloaded class after the first edit.
    #
    # Idempotent by construction: `SpreePos.register` is a Hash assignment
    # keyed on `.key`, so running it repeatedly is a no-op beyond
    # re-validating the contract (cheap, and a genuinely useful assertion
    # to re-run after a reload).
    #
    # `spree_pos` is a hard gemspec dependency of this gem, so `SpreePos`
    # is always defined by the time this runs; the `defined?` guard is for
    # the one case that is not true — a host app that loaded this engine
    # without the dependency resolved (broken Gemfile state) — where a
    # NameError here would be a confusing way to find out.
    def self.register_pos_provider!
      return unless defined?(::SpreePos) && ::SpreePos.respond_to?(:register)

      ::SpreePos.register(::SpreeSquare::Provider)
    end

    config.to_prepare(&method(:activate).to_proc)
  end
end
