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
    end

    config.to_prepare(&method(:activate).to_proc)
  end
end
