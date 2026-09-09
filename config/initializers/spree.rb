# Modifier support (M4): let `square_modifier_ids` survive the options
# hash that Spree::Cart::AddItem filters incoming `options:` params through,
# so it reaches Variant#square_modifier_ids_price_modifier_amount (the
# initial price) and LineItem#square_modifier_ids (read by
# SpreePos::Cart::AddItem to build the persistent snapshot rows).
Spree::PermittedAttributes.line_item_attributes << :square_modifier_ids

# Phase 2 (sequence step 12c): Cart::AddItem and FindLineItemByVariant moved
# to spree_pos -- their Spree.dependencies registration now lives in
# spree_host's own config/initializers/spree.rb (spree_pos has no
# initializer of its own yet; that consolidation is a later phase step),
# pointing at SpreePos:: instead of SpreeSquare::.

Spree::Api::Dependencies.product_serializer = 'SpreeSquare::ProductSerializer'
Spree::Api::Dependencies.line_item_serializer = 'SpreeSquare::LineItemSerializer'

# Uncomment lines below to add your own custom business logic
# such as promotions, shipping methods, etc.
Rails.application.config.after_initialize do
  # M5: push a completed order to Square (as an already-paid ticket) as soon
  # as Spree marks it complete.
  Spree.subscribers << SpreeSquare::OrderCompletedSubscriber

  # Spree.shipping_methods << Spree::ShippingMethods::SuperExpensiveNotVeryFastShipping
  # Spree.payment_methods << Spree::PaymentMethods::VerySafeAndReliablePaymentMethod

  # Spree.calculators.tax_rates << Spree::TaxRates::FinanceTeamForcedMeToCodeThis

  # Spree.stock_splitters << Spree::Stock::Splitters::SecretLogicSplitter

  # Spree.adjusters << Spree::Adjustable::Adjuster::TaxTheRich

  # Custom promotions
  # Spree.calculators.promotion_actions_create_adjustments << Spree::Calculators::PromotionActions::CreateAdjustments::AddDiscountForFriends
  # Spree.calculators.promotion_actions_create_item_adjustments << Spree::Calculators::PromotionActions::CreateItemAdjustments::FinanceTeamForcedMeToCodeThis
  # Spree.promotions.rules << Spree::Promotions::Rules::OnlyForVIPCustomers
  # Spree.promotions.actions << Spree::Promotions::Actions::GiftWithPurchase

  # Spree.taxon_rules << Spree::TaxonRules::ProductsWithColor

  # Spree.exports << Spree::Exports::Payments
  # Spree.reports << Spree::Reports::MassivelyOvercomplexReportForCfo
end
