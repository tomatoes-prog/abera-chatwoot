module Abera::MessageQuota
  extend ActiveSupport::Concern

  included do
    validate :abera_check_message_rate, on: :create
  end

  private

  def abera_check_message_rate
    return unless Abera.enabled? && account && !Abera::Current.administrative_operation

    subscription = account.abera_subscription
    return unless subscription

    errors.add(:base, I18n.t('abera.limits.messages')) unless Abera::RateLimit.allowed?(subscription, 'messages', 60)
  end
end
