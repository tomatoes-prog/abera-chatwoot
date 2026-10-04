module Abera::MessageDurability
  extend ActiveSupport::Concern

  prepended do
    after_create :abera_persist_reply
  end

  private

  def abera_persist_reply
    return unless Abera.enabled? && account.abera_subscription && !Abera::Current.administrative_operation

    # The message and its delivery intent commit together. The dispatcher is
    # notified only after commit; attachment uploads retain the native delay.
    attachments.blank? ? SendReplyJob.perform_later(id) : SendReplyJob.set(wait: 2.seconds).perform_later(id)
  end

  def send_reply
    return if Abera.enabled? && account.abera_subscription

    super
  end
end
