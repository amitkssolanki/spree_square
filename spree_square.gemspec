# encoding: UTF-8
lib = File.expand_path('../lib/', __FILE__)
$LOAD_PATH.unshift lib unless $LOAD_PATH.include?(lib)

require 'spree_square/version'

Gem::Specification.new do |s|
  s.platform    = Gem::Platform::RUBY
  s.name        = 'spree_square'
  s.version     = SpreeSquare::VERSION
  s.summary     = 'Spree Commerce Square Extension'
  s.description = 'Syncs a Square catalog (items, variations, categories, images, modifiers) into ' \
                   'Spree Commerce, pushes completed Spree orders into Square as paid tickets, and ' \
                   'keeps fulfillment status in sync in both directions via webhooks. Supports ' \
                   'self-service OAuth ("Connect to Square" in the admin) as well as a hand-issued ' \
                   'access token for local development.'
  s.required_ruby_version = '>= 3.2'

  s.author    = 'Amit Solanki'
  s.email     = 'amitkssolanki@gmail.com'
  s.homepage  = 'https://github.com/amitkssolanki/spree_square'
  s.license   = 'MIT'

  s.metadata = {
    'homepage_uri' => s.homepage,
    'source_code_uri' => s.homepage,
    'changelog_uri' => "#{s.homepage}/blob/main/CHANGELOG.md",
    'bug_tracker_uri' => "#{s.homepage}/issues"
  }

  # `git ls-files` (not a manual Dir[] glob) so the package always matches
  # what's actually tracked in the repo — and so the demo-menu example
  # content below (restaurant-specific, not something every installer wants
  # bundled in) can be excluded by path without needing to keep two lists in
  # sync by hand.
  s.files = `git ls-files -z`.split("\x0").reject do |f|
    (f.start_with?('spec/') && !f.start_with?('spec/fixtures')) ||
      f.start_with?('lib/tasks/demo_menu')
  end
  s.require_path = 'lib'
  s.requirements << 'none'

  spree_version = '>= 5.4.0.beta'
  s.add_dependency 'spree', spree_version
  s.add_dependency 'spree_admin', spree_version

  # Square's official Ruby SDK. Current major (Fern-generated) uses
  # Square::Client.new(token:) / square.orders.create(...) — NOT the legacy
  # client.orders_api.create_order shape most tutorials show (that's the
  # square_legacy export within this same gem; we don't use it).
  s.add_dependency 'square.rb', '~> 46.0'

  s.add_development_dependency 'spree_dev_tools'
  s.add_development_dependency 'webmock'
  s.add_development_dependency 'gem-release'
end
