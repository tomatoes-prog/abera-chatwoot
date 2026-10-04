class Abera::Subscription < ApplicationRecord
  self.table_name = 'abera_subscriptions'

  belongs_to :account, inverse_of: :abera_subscription
  has_one :smtp_setting, through: :account, source: :abera_smtp_setting
  has_many :usage_windows, class_name: 'Abera::UsageWindow', foreign_key: :abera_subscription_id, inverse_of: :subscription, dependent: :delete_all
  has_many :durable_jobs, class_name: 'Abera::DurableJob', foreign_key: :abera_subscription_id, inverse_of: :subscription, dependent: :delete_all

  validates :subscription_id, :customer_id, :service_host, presence: true
  validates :subscription_id, :service_host, uniqueness: true
  validates :tier, inclusion: { in: %w[lite essential professional] }
  validates :state, inclusion: { in: %w[pending active suspended quiescing archived] }
  validates :agent_limit, :conversation_limit, :storage_limit_bytes, numericality: { only_integer: true, greater_than: 0 }

  def usable?
    state == 'active' && account.active?
  end

  def cycle_start(at = Time.current)
    anchor = activated_at || created_at
    anchor + (((at - anchor) / 31.days).floor.clamp(0, Float::INFINITY) * 31.days)
  end

  def service_url
    "https://#{service_host}"
  end
end
