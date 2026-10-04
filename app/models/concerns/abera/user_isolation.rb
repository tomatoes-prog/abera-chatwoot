module Abera::UserIsolation
  def visible_account_users
    return super unless Abera.enabled?

    subscription = Abera::Current.subscription
    raise 'Managed profile requires a subscription context' unless subscription

    super.where(account_id: subscription.account_id)
  end
end
