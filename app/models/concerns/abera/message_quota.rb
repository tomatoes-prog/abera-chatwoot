module Abera::MessageQuota
  extend ActiveSupport::Concern

  included do
    validate :abera_check_message_rate, on: :create
  end

  private

  def abera_check_message_rate
    subscription = account.abera_subscription
    return unless Abera.enabled? && subscription && !Abera::Current.administrative_operation

    errors.add(:base, I18n.t('abera.limits.messages')) unless Abera::RateLimit.allowed?(subscription, 'messages', 60)
  end
end
