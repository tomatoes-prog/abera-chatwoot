module Abera::FacebookDeliveryIsolation
  private

  def facebook_channel
    return super unless Abera.enabled?

    subscription = Abera::Current.subscription
    raise ActiveRecord::RecordNotFound unless subscription

    @facebook_channel ||= Channel::FacebookPage.find_by!(account_id: subscription.account_id, page_id: params.recipient_id)
  end

  def contact
    return super unless Abera.enabled?

    Abera::TenantGuard.check!(facebook_channel.account)
    ContactInbox.find_by(inbox_id: facebook_channel.inbox.id, source_id: params.sender_id)&.contact
  end

  def conversation
    return super unless Abera.enabled?

    @conversation ||= facebook_channel.inbox.conversations.find_by(contact_id: contact.id) if contact.present?
  end
end
