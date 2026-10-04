class Abera::JobContext
  def self.subscription(job)
    account = account_for(job)
    current = Abera::Current.subscription
    raise ActiveRecord::RecordNotFound if Abera.enabled? && current && account && account.id != current.account_id

    account&.abera_subscription
  end

  def self.account_for(job)
    return Abera::WebhookContext.account(job) if job.class.name.start_with?('Webhooks::')

    case job.class.name
    when 'ActionCableBroadcastJob' then Account.find(job.arguments.fetch(2).fetch(:account_id))
    else
      Abera::JobReferences.account(job) || Abera::AccountContext.resolve(job.arguments) || Current.account
    end
  end
  private_class_method :account_for
end
