module Abera::ConnectionIsolation
  def connect
    return super if !Abera.enabled? && defined?(super)
    return unless Abera.enabled?

    self.abera_subscription_id = Abera::Subscription.find_by!(service_host: request.host.downcase).id
    reject_unauthorized_connection unless Abera::Subscription.find(abera_subscription_id).usable?
  rescue ActiveRecord::RecordNotFound
    reject_unauthorized_connection
  end
end
