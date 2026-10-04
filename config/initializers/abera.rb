require Rails.root.join('lib/abera')
require Rails.root.join('lib/abera/tenant_middleware')

Rails.application.config.middleware.use Abera::TenantMiddleware

if Abera.enabled?
  Rails.application.config.x[:account_frontend_url_resolver] = lambda do |account|
    raise ArgumentError, 'An account is required to generate a managed service URL' unless account

    subscription = Abera::Current.subscription
    subscription = Abera::Subscription.find_by!(account_id: account.id) unless subscription&.account_id == account.id
    subscription.service_url
  end
end

Rails.application.config.to_prepare do
  Account.has_one :abera_subscription, class_name: 'Abera::Subscription', inverse_of: :account, dependent: :destroy
  Account.has_one :abera_smtp_setting, class_name: 'Abera::SmtpSetting', inverse_of: :account, dependent: :destroy
  Conversation.include Abera::ConversationQuota
  AccountUser.include Abera::AgentQuota
  User.prepend Abera::UserIsolation
  Message.include Abera::MessageQuota
  Message.prepend Abera::MessageDurability
  ActiveSupport.on_load(:active_storage_blob) { include Abera::BlobOwnership }
  ActiveSupport.on_load(:active_storage_attachment) { include Abera::AttachmentIsolation }
  ActiveStorage::DirectUploadsController.include Abera::DirectUploadIsolation
  ApplicationMailer.prepend Abera::MailerDelivery
  ApplicationJob.include Abera::DurableEnqueue
  ActionMailer::MailDeliveryJob.include Abera::DurableEnqueue
  ActionCableBroadcastJob.prepend Abera::BroadcastIsolation
  Integrations::Facebook::DeliveryStatus.prepend Abera::FacebookDeliveryIsolation
  WebsiteTokenHelper.prepend Abera::ChannelIsolation
  WidgetsController.prepend Abera::ChannelIsolation
  Public::Api::V1::InboxesController.prepend Abera::PublicInboxIsolation
  Webhooks::WhatsappController.prepend Abera::WhatsappIsolation
  ApplicationCable::Connection.identified_by :abera_subscription_id
  ApplicationCable::Connection.prepend Abera::ConnectionIsolation
  RoomChannel.prepend Abera::RoomIsolation
  ApplicationController.include Abera::AccountRouteIsolation
  ApplicationController.rescue_from(Abera::Quota::Exceeded) do |error|
    render json: { error: error.message }, status: :too_many_requests
  end
  PublicController.rescue_from(Abera::Quota::Exceeded) do |error|
    render json: { error: error.message }, status: :too_many_requests
  end
end
