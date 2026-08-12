module SpreeSquare
  # Verifies the `x-square-hmacsha256-signature` header Square sends on every
  # webhook POST. Algorithm per Square's spec (mirrored from the legacy SDK's
  # WebhooksHelper, since the current SDK doesn't ship a verifier — Square's
  # signing scheme itself, not the SDK's shape, is what this depends on):
  #
  #   base64(HMAC-SHA256(signing_key, notification_url + raw_request_body))
  #
  # compared against the header using a constant-time comparison.
  class WebhookVerifier
    def self.valid?(url:, body:, signature:, signing_key:)
      return false if body.nil? || signature.blank? || signing_key.blank?

      payload = "#{url}#{body}".dup.force_encoding('UTF-8')
      digest = OpenSSL::HMAC.digest('sha256', signing_key.dup.force_encoding('UTF-8'), payload)
      expected = Base64.strict_encode64(digest)

      ActiveSupport::SecurityUtils.secure_compare(expected, signature)
    end
  end
end
