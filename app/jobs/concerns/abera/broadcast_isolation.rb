module Abera::BroadcastIsolation
  def perform(members, event_name, data)
    return super unless Abera.enabled?

    subscription = Abera::Subscription.find_by!(account_id: data.fetch(:account_id))
    Abera::TenantLock.with_access(subscription) do |managed|
      next unless managed.usable?

      streams = members.map { |member| "abera:#{managed.subscription_id}:#{member}" }
      super(streams, event_name, data)
    end
  end
end
