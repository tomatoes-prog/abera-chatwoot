module Abera::AttachmentIsolation
  extend ActiveSupport::Concern

  included do
    validate :abera_check_blob_ownership
  end

  private

  def abera_check_blob_ownership
    return unless Abera.enabled? && !Abera::Current.administrative_operation

    account = record.respond_to?(:account) ? record.account : Current.account
    subscription = account&.abera_subscription
    errors.add(:blob, :invalid) unless subscription && blob.metadata['abera_subscription_id'] == subscription.subscription_id
  end
end
