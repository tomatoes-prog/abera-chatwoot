class Abera::DurableJob < ApplicationRecord
  self.table_name = 'abera_durable_jobs'
  belongs_to :subscription, class_name: 'Abera::Subscription', foreign_key: :abera_subscription_id, inverse_of: :durable_jobs
  validates :job_class, :deduplication_key, presence: true

  after_create_commit :dispatch

  def dispatch
    return if Abera::Current.administrative_operation

    Abera::DispatchJob.enqueue(abera_subscription_id)
  rescue Redis::BaseError, RedisClient::Error
    Rails.logger.warn("Abera durable work awaiting dispatcher: subscription=#{abera_subscription_id}")
  end
end
