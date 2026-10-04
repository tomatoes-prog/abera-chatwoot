class Abera::WebhookContext
  DIRECT_CHANNELS = {
    'Webhooks::TelegramEventsJob' => [Channel::Telegram, :bot_token, :bot_token],
    'Webhooks::SmsEventsJob' => [Channel::Sms, :phone_number, :to],
    'Webhooks::TiktokEventsJob' => [Channel::Tiktok, :business_id, :user_openid]
  }.freeze
  TWILIO_SERVICES = {
    'Webhooks::TwilioEventsJob' => Twilio::IncomingMessageService,
    'Webhooks::TwilioDeliveryStatusJob' => Twilio::DeliveryStatusService
  }.freeze

  def self.account(job)
    payload = job.arguments.first
    channels = channels_for(job, payload)
    raise ActiveRecord::RecordNotFound if channels.empty? || channels.any?(&:nil?)

    Abera::AccountContext.resolve(channels)
  end

  def self.channels_for(job, payload)
    if DIRECT_CHANNELS.key?(job.class.name)
      model, attribute, key = DIRECT_CHANNELS.fetch(job.class.name)
      return [model.find_by!(attribute => payload.with_indifferent_access.fetch(key))]
    end
    service = TWILIO_SERVICES[job.class.name]
    return [service.new(params: payload.with_indifferent_access).send(:twilio_channel)] if service

    provider_channels(job, payload)
  end

  def self.provider_channels(job, payload)
    case job.class.name
    when 'Webhooks::WhatsappEventsJob'
      Abera::WhatsappPayloads.split(payload).map { |event| job.send(:find_channel_from_whatsapp_business_payload, event) }
    when 'Webhooks::LineEventsJob'
      parameters = payload.with_indifferent_access.fetch(:params).with_indifferent_access
      [Channel::Line.find_by!(line_channel_id: parameters.fetch(:line_channel_id))]
    when 'Webhooks::FacebookEventsJob', 'Webhooks::FacebookDeliveryJob'
      response = Integrations::Facebook::MessageParser.new(payload)
      facebook_channels(response)
    when 'Webhooks::InstagramEventsJob'
      instagram_channels(job, payload)
    else
      raise "Managed webhook context is not implemented: #{job.class.name}"
    end
  end

  def self.facebook_channels(response)
    channels = Channel::FacebookPage.where(page_id: [response.sender_id, response.recipient_id])
    subscription = Abera::Current.subscription
    channels = channels.where(account_id: subscription.account_id) if subscription
    channels.to_a
  end

  def self.instagram_channels(job, entries)
    entries.flat_map do |entry|
      entry = entry.with_indifferent_access
      messages = job.send(:messages, entry)
      messages = [job.send(:extract_messaging_from_test_event, entry)].compact if entry[:changes].present?
      messages.map do |message|
        identifier = job.send(:instagram_id, message.with_indifferent_access)
        job.send(:find_channel, identifier)
      end
    end
  end
  private_class_method :channels_for, :provider_channels, :facebook_channels, :instagram_channels
end
