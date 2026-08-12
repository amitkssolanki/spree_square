module SpreeSquare
  class BaseJob < Spree::BaseJob
    queue_as SpreeSquare.queue
  end
end
