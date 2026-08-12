require 'net/http'

module SpreeSquare
  # Tells the Next.js storefront which Cache Components tags to drop after a
  # sync write, so a price/menu/inventory change from Square shows up
  # immediately instead of waiting out the storefront's cacheLife("tenMinutes")
  # window.
  #
  # Deliberately not routed through Spree's own outbound webhook system
  # (Spree::WebhookEndpoint): that system's `product.updated` event is
  # suppressed on touch-only cascades, which is exactly how a price or stock
  # change reaches the product (variant/price/stock_item touch the product,
  # they don't update it directly) — so it would silently miss most of what
  # this extension syncs. This service is called directly from the sync code,
  # which already knows the exact product with no ambiguity.
  #
  # Failure here is logged, never raised — a stale storefront cache for up to
  # 10 minutes is a much smaller problem than a failed revalidation call
  # breaking catalog or inventory sync.
  class Revalidator
    def self.call(...) = new.call(...)

    def call(tags)
      return if url.blank? || secret.blank? || tags.blank?

      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 2
      http.read_timeout = 2

      request = Net::HTTP::Post.new(uri.request_uri)
      request['Content-Type'] = 'application/json'
      request['x-revalidate-secret'] = secret
      request.body = { tags: Array(tags) }.to_json

      response = http.request(request)
      unless response.is_a?(Net::HTTPSuccess)
        Rails.logger.warn("[SpreeSquare] revalidate call failed (#{response.code}): #{response.body}")
      end
    rescue StandardError => e
      Rails.logger.warn("[SpreeSquare] revalidate call errored: #{e.message}")
    end

    private

    def url
      ENV['STOREFRONT_REVALIDATE_URL']
    end

    def secret
      ENV['STOREFRONT_REVALIDATE_SECRET']
    end
  end
end
