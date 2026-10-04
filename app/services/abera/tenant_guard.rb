class Abera::TenantGuard
  def self.check!(account)
    return unless Abera.enabled?

    subscription = Abera::Current.subscription
    raise ActiveRecord::RecordNotFound unless subscription&.usable? && account&.id == subscription.account_id
  end
end
