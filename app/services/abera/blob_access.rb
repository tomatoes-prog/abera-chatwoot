class Abera::BlobAccess
  def self.allowed?(blob, subscription)
    return true if blob.metadata['abera_subscription_id'] == subscription.subscription_id
    return false unless Avatarable::ALLOWED_AVATAR_CONTENT_TYPES.include?(blob.content_type)
    return false if blob.attachments.exists?(['record_type != ? OR name != ?', 'User', 'avatar'])

    blob.attachments.exists?(record_type: 'User', name: 'avatar', record_id: subscription.account.users.select(:id))
  end
end
