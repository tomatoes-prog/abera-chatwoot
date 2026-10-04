module Abera::ConversationQuota
  extend ActiveSupport::Concern

  included do
    before_create { Abera::Quota.reserve_conversation!(account) }
  end
end
