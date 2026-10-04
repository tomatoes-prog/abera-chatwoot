module Abera::ChannelIsolation
  def set_web_widget
    super
    Abera::TenantGuard.check!(@web_widget&.inbox&.account)
  end
end
