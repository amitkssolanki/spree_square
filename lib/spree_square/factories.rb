FactoryBot.define do
  # Define your Spree extensions Factories within this file to enable applications, and other extensions to use and override them.
  #
  # Example adding this to your spec_helper will load these Factories for use:
  # require 'spree_square/factories'

  factory :square_credential, class: 'SpreeSquare::Credential' do
    store
    sequence(:square_merchant_id) { |i| "MERCHANT#{i}" }
    access_token { 'test-access-token' }
    refresh_token { 'test-refresh-token' }
    square_environment { 'sandbox' }
    expires_at { 30.days.from_now }
    refresh_token_expires_at { 90.days.from_now }
  end
end
