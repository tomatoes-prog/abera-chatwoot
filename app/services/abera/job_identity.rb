class Abera::JobIdentity
  DELIVERY_JOBS = %w[SendReplyJob ConversationReplyEmailJob].freeze

  def self.key(payload)
    name = payload.fetch('job_class')
    critical = DELIVERY_JOBS.include?(name) || name.start_with?('Webhooks::')
    arguments = event_identity(name, payload.fetch('arguments'))
    identity = critical ? [name, arguments, payload.fetch('executions')] : payload.fetch('job_id')
    Digest::SHA256.hexdigest(JSON.generate(identity))
  end

  def self.event_identity(name, arguments)
    return canonical(arguments) unless name == 'Webhooks::TelegramEventsJob'

    event = arguments.first.with_indifferent_access
    update_id = event.dig(:telegram, :update_id) || event.fetch(:update_id)
    [event.fetch(:bot_token), update_id]
  end

  def self.canonical(value)
    case value
    when Array then value.map { |item| canonical(item) }
    when Hash then value.sort.to_h.transform_values { |item| canonical(item) }
    else value
    end
  end
  private_class_method :canonical, :event_identity
end
