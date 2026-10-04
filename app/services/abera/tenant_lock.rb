class Abera::TenantLock
  def self.key(subscription_id)
    Digest::SHA256.hexdigest("abera-tenant:#{subscription_id}")[0, 15].to_i(16)
  end

  # Requests and workers may run together. Lifecycle operations wait until both
  # finish, then change state while holding the exclusive transaction lock.
  def self.with_access(subscription)
    ApplicationRecord.connection_pool.with_connection do |connection|
      lock_id = key(subscription.subscription_id)
      connection.execute("SELECT pg_advisory_lock_shared(#{lock_id})")
      begin
        yield subscription.reload
      ensure
        connection.execute("SELECT pg_advisory_unlock_shared(#{lock_id})")
      end
    end
  end

  def self.exclusive!(subscription)
    ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(#{key(subscription.subscription_id)})")
  end
end
