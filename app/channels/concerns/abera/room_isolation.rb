module Abera::RoomIsolation
  def subscribed
    if Abera.enabled?
      subscription = Abera::Subscription.find(connection.abera_subscription_id)
      current_user
      current_account
      return reject unless subscription.usable? && @current_account&.id == subscription.account_id
    end
    super
  end

  def update_presence
    if Abera.enabled?
      subscription = Abera::Subscription.find(connection.abera_subscription_id)
      return reject unless subscription.usable? && @current_account&.id == subscription.account_id
    end
    super
  end

  private

  def ensure_stream
    return super unless Abera.enabled?

    subscription = Abera::Subscription.find(connection.abera_subscription_id)
    prefix = "abera:#{subscription.subscription_id}:"
    streams = ["#{prefix}#{pubsub_token}"]
    streams << "#{prefix}account_#{@current_account.id}" if @current_user.is_a?(User)
    streams.each { |stream| stream_from(stream, coder: ActiveSupport::JSON) { |message| abera_transmit(message) } }
  end

  def abera_transmit(message)
    subscription = Abera::Subscription.find(connection.abera_subscription_id)
    Abera::TenantLock.with_access(subscription) do |managed|
      if abera_receiver_authorized?(managed)
        transmit(message)
      else
        stop_all_streams
        reject
      end
    end
  rescue ActiveRecord::RecordNotFound
    stop_all_streams
    reject
  end

  def abera_receiver_authorized?(subscription)
    return false unless subscription.usable? && @current_account&.id == subscription.account_id
    return subscription.account.account_users.exists?(user_id: @current_user.id) if @current_user.is_a?(User)

    ContactInbox.joins(:inbox).exists?(pubsub_token: pubsub_token, contact_id: @current_user.id,
                                       inboxes: { account_id: subscription.account_id })
  end

  def broadcast_presence
    return super unless Abera.enabled?

    subscription = Abera::Subscription.find(connection.abera_subscription_id)
    return unless subscription.usable? && @current_account&.id == subscription.account_id

    data = { account_id: @current_account.id, users: ::OnlineStatusTracker.get_available_users(@current_account.id) }
    data[:contacts] = ::OnlineStatusTracker.get_available_contacts(@current_account.id) if @current_user.is_a?(User)
    ActionCable.server.broadcast("abera:#{subscription.subscription_id}:#{pubsub_token}", { event: 'presence.update', data: data })
  end
end
