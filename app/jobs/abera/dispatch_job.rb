class Abera::DispatchJob < ApplicationJob
  queue_as :default

  def self.enqueue(subscription_id)
    token = SecureRandom.hex(16)
    return unless Redis::Alfred.set("abera:dispatch:#{subscription_id}", token, nx: true, ex: 60)

    new(subscription_id, token).enqueue
  end

  def perform(subscription_id, token)
    acquired = false
    subscription = Abera::Subscription.find(subscription_id)
    Abera::TenantLock.with_access(subscription) do |managed|
      next unless managed.usable?

      connection = ApplicationRecord.connection
      lock_id = Digest::SHA256.hexdigest("abera-jobs:#{subscription_id}")[0, 15].to_i(16)
      acquired = connection.select_value("SELECT pg_try_advisory_lock(#{lock_id})")
      next unless acquired

      begin
        execute_one(managed)
      ensure
        connection.execute("SELECT pg_advisory_unlock(#{lock_id})")
      end
    end
  ensure
    Redis::Alfred.delete_if_equals("abera:dispatch:#{subscription_id}", token)
    if acquired && subscription&.usable? && subscription.durable_jobs.where(state: 'pending').exists?(['available_at <= ?', Time.current])
      self.class.enqueue(subscription_id)
    end
  end

  private

  def execute_one(subscription)
    work = subscription.durable_jobs.where(state: %w[pending running]).where('available_at <= ?', Time.current).order(:created_at).first
    return unless work

    work.update!(state: 'running', attempts: work.attempts + 1)
    Current.account = subscription.account
    Abera::Current.subscription = subscription
    ActiveJob::Base.deserialize(work.arguments).perform_now
    work.update!(state: 'completed', completed_at: Time.current, last_error: nil)
  rescue StandardError => e
    fail_work(work, e) if work
    raise
  ensure
    Current.reset
    Abera::Current.reset
  end

  def fail_work(work, error)
    maximum_attempts = work.job_class == 'Abera::SmtpTestJob' ? 1 : 10
    work.update!(state: work.attempts >= maximum_attempts ? 'failed' : 'pending', available_at: 1.minute.from_now,
                 last_error: error.class.name)
  end
end
