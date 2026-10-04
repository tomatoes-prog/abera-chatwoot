class Abera::Quota
  class Exceeded < StandardError; end

  def self.reserve_conversation!(account)
    subscription = account.abera_subscription
    return unless Abera.enabled? && subscription && !Abera::Current.administrative_operation

    subscription.with_lock do
      window = subscription.usage_windows.find_or_create_by!(starts_at: subscription.cycle_start)
      raise Exceeded, I18n.t('abera.limits.conversations') if window.conversations >= subscription.conversation_limit

      window.update!(conversations: window.conversations + 1)
    end
  end

  def self.reserve_storage!(subscription, bytes)
    subscription.with_lock do
      raise Exceeded, I18n.t('abera.limits.file_size') if bytes > 10.megabytes
      raise Exceeded, I18n.t('abera.limits.storage') if subscription.storage_reserved_bytes + bytes > subscription.storage_limit_bytes

      subscription.update!(storage_reserved_bytes: subscription.storage_reserved_bytes + bytes)
    end
  end
end
