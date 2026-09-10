# Stands in for the real SpreeSquare::Provider registration, which does not
# exist anywhere in this codebase yet (verified via grep — see this batch's
# report: "SpreePos::OrderStatusMapper / provider registration" integration
# seam). SpreePos::WebhooksController resolves :square through
# `SpreePos.provider(params[:provider])`, so any spec exercising
# `POST /spree_pos/webhooks/square` end-to-end needs *something* registered
# under that key. #webhooks is unused by the controller under test — it
# calls SpreeSquare::WebhookAdapter directly — this class exists purely so
# the registry lookup resolves instead of raising ArgumentError, mirroring
# spree_pos's own spec/support/fake_provider.rb pattern.
class FakeSquareProviderForWebhookRouting < SpreePos::Provider
  def self.key = :square
  def self.display_name = 'Square (fake registration, webhook routing specs only)'
  def self.capabilities = SpreePos::Capability::MANDATORY

  def auth      = raise NotImplementedError
  def locations = raise NotImplementedError
  def catalog   = raise NotImplementedError
  def orders    = raise NotImplementedError
  def webhooks  = raise NotImplementedError
end
