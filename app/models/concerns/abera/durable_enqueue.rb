module Abera::DurableEnqueue
  extend ActiveSupport::Concern

  included do
    around_enqueue do |job, enqueue|
      subscription = Abera::JobContext.subscription(job) if Abera.enabled? && !job.is_a?(Abera::DispatchJob)
      if subscription
        subscription.with_lock do
          payload = job.serialize
          key = Abera::JobIdentity.key(payload)
          unless subscription.durable_jobs.exists?(deduplication_key: key)
            raise Abera::Quota::Exceeded, I18n.t('abera.limits.pending_jobs') if subscription.durable_jobs.where(state: %w[pending
                                                                                                                           running]).count >= 250

            subscription.durable_jobs.create!(job_class: job.class.name, deduplication_key: key, arguments: payload,
                                              available_at: job.scheduled_at ? Time.zone.at(job.scheduled_at) : Time.current)
          end
        end
        job.successfully_enqueued = true
      else
        enqueue.call
      end
    end
  end
end
