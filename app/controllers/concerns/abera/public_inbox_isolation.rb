module Abera::PublicInboxIsolation
  def set_inbox_channel
    super
    Abera::TenantGuard.check!(@inbox_channel.account) if @inbox_channel
  end

  def show
    super
    Abera::TenantGuard.check!(@inbox_channel.account)
  end
end
