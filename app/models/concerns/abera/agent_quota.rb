module Abera::AgentQuota
  extend ActiveSupport::Concern

  included do
    validate :abera_check_agent_quota, on: :create
  end

  private

  def abera_check_agent_quota
    subscription = account.abera_subscription
    return unless Abera.enabled? && subscription && !Abera::Current.administrative_operation

    subscription.with_lock do
      errors.add(:base, I18n.t('abera.limits.agents')) if account.account_users.count >= subscription.agent_limit
    end
  end
end
