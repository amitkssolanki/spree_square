# Modifier support (M4): let `square_modifier_ids` survive the options
# hash that Spree::Cart::AddItem filters incoming `options:` params through,
# so it reaches Variant#square_modifier_ids_price_modifier_amount (the
# initial price) and LineItem#square_modifier_ids (read by
# SpreeSquare::Cart::AddItem to build the persistent snapshot rows).
Spree::PermittedAttributes.line_item_attributes << :square_modifier_ids

Spree.dependencies do |dependencies|
  dependencies.cart_add_item_service = 'SpreeSquare::Cart::AddItem'
  # cart_compare_line_items_service is NOT the merge gate it looks like —
  # Spree::LineItems::FindByVariant calls it but discards the result. The
  # finder itself is the actual hook (see find_line_item_by_variant.rb).
  dependencies.line_item_by_variant_finder = 'SpreeSquare::FindLineItemByVariant'
end

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
