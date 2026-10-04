module Abera::AccountRouteIsolation
  extend ActiveSupport::Concern

  included do
    before_action :abera_validate_account_route
  end

  private

  def abera_validate_account_route
    return unless Abera.enabled?

    subscription = Abera::Current.subscription
    abera_validate_membership(subscription) if controller_path.start_with?('api/') && Current.user
    account_id = abera_routed_account_id
    return unless account_id

    abera_validate_routed_account_id(subscription, account_id)
  end

  def abera_validate_routed_account_id(subscription, account_id)
    valid = account_id.to_s.match?(/\A\d+\z/) && subscription && account_id.to_i == subscription.account_id
    raise ActiveRecord::RecordNotFound unless valid
  end

  def abera_validate_membership(subscription)
    raise ActiveRecord::RecordNotFound unless subscription && Current.user.account_users.exists?(account_id: subscription.account_id)
  end

  def abera_routed_account_id
    return params[:account_id] if params[:account_id]
    return params[:id] if controller_path == 'api/v1/accounts'
    return unless controller_path == 'api/v1/profiles' && params[:profile].is_a?(ActionController::Parameters)

    params[:profile][:account_id]
  end
end
