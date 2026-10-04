module Abera::MailerDelivery
  def process(action, *args, **kwargs)
    previous_account = Current.account
    return super unless Abera.enabled?

    @abera_mail_account = Abera::AccountContext.resolve([params, args, kwargs]) || Current.account
    raise 'Account context is required for managed email' unless @abera_mail_account&.abera_subscription

    Current.account = @abera_mail_account
    super
  ensure
    Current.account = previous_account if Abera.enabled?
  end

  def smtp_config_set_or_development?
    return super unless Abera.enabled?

    @abera_mail_account&.abera_smtp_setting.present?
  end

  def mail(headers = {}, &)
    return super unless Abera.enabled?

    setting = @abera_mail_account.abera_smtp_setting
    return unless setting

    headers[:from] = setting.sender unless defined?(@inbox) && @inbox&.email?
    headers[:delivery_method] = :smtp
    headers[:delivery_method_options] = setting.delivery_options.merge(headers[:delivery_method_options] || {}).merge(openssl_verify_mode: 'peer')
    headers[:delivery_method_options][:open_timeout] = 5
    headers[:delivery_method_options][:read_timeout] = 10
    super(headers, &)
  end

  def ensure_current_account(account)
    return super unless Abera.enabled?

    Current.account = @abera_mail_account
  end

  def default_url_options
    return super unless Abera.enabled? && @abera_mail_account

    super.merge(host: @abera_mail_account.abera_subscription.service_host, protocol: 'https')
  end
end
