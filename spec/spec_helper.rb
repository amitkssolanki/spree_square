# Configure Rails Environment
ENV['RAILS_ENV'] = 'test'

require 'dotenv/load'

require File.expand_path('../dummy/config/environment.rb', __FILE__)

require 'spree_dev_tools/rspec/spec_helper'
require 'spree_square/factories'
# spree_pos's factories (:pos_connection, :pos_location, ...) — needed by
# the provider-contract shared example and the registry-dispatch specs,
# which have to build real SpreePos records to resolve a provider from.
require 'spree_pos/factories'
# The shared 'a POS provider' example group SpreeSquare::Provider is
# verified against.
require 'spree_pos/testing_support/provider_contract'

require 'webmock/rspec'
# Square API calls are stubbed per-example; anything else hitting the network
# (a typo'd URL, a forgotten stub) fails loudly instead of making a real
# request. localhost stays open for the dummy app's own request specs.
WebMock.disable_net_connect!(allow_localhost: true)

# Requires supporting ruby files with custom matchers and macros, etc,
# in spec/support/ and its subdirectories.
Dir[File.join(File.dirname(__FILE__), 'support/**/*.rb')].sort.each { |f| require f }
