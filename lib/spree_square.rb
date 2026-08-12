require 'spree'
require 'spree_square/engine'
require 'spree_square/version'
require 'spree_square/configuration'

module SpreeSquare
  mattr_accessor :queue

  def self.queue
    @@queue ||= Spree.queues.default
  end
end
