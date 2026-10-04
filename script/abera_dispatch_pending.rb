# Run in a separate container using the same image as Rails and Sidekiq.
# Polling PostgreSQL also recovers the scheduler after Redis data loss.
raise 'Managed mode is required' unless Abera.enabled?

loop do
  Rails.application.executor.wrap do
    Abera::DurableJob.where(state: %w[pending running]).where('available_at <= ?', Time.current)
                     .distinct.pluck(:abera_subscription_id).each do |subscription_id|
      Abera::DispatchJob.enqueue(subscription_id)
    end
    Abera::DurableJob.where(state: 'completed').where('completed_at < ?', 7.days.ago).delete_all
  end
  sleep 30
rescue Redis::BaseError, RedisClient::Error
  Rails.logger.warn('Abera dispatcher waiting for Redis')
  sleep 30
end
