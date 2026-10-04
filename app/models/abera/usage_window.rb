class Abera::UsageWindow < ApplicationRecord
  self.table_name = 'abera_usage_windows'

  belongs_to :subscription, class_name: 'Abera::Subscription', foreign_key: :abera_subscription_id, inverse_of: :usage_windows
end
