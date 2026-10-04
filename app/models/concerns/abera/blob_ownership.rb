module Abera::BlobOwnership
  extend ActiveSupport::Concern

  included do
    before_create :abera_reserve_blob
    after_destroy :abera_release_blob
  end

  private

  def abera_reserve_blob
    subscription = Abera::Current.subscription || Current.account&.abera_subscription
    return unless Abera.enabled? && subscription && !Abera::Current.administrative_operation

    Abera::Quota.reserve_storage!(subscription, byte_size)
    self.metadata = metadata.merge('abera_subscription_id' => subscription.subscription_id)
    self.key = "subscriptions/#{subscription.subscription_id}/#{key || self.class.generate_unique_secure_token}"
  end

  def abera_release_blob
    subscription_id = metadata['abera_subscription_id']
    return unless subscription_id && Abera.enabled? && !Abera::Current.administrative_operation

    subscription = Abera::Subscription.find_by(subscription_id: subscription_id)
    subscription&.with_lock { subscription.update!(storage_reserved_bytes: [subscription.storage_reserved_bytes - byte_size, 0].max) }
  end
end
