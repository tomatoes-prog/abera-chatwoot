class Abera::SmtpTestJob < ApplicationJob
  queue_as :default

  def perform(account_id, user_id)
    account = Account.find(account_id)
    user = account.users.find(user_id)
    setting = account.abera_smtp_setting || raise(ActiveRecord::RecordNotFound)
    Mail.new(from: setting.sender, to: user.email, subject: I18n.t('abera.smtp.test_subject'),
             body: I18n.t('abera.smtp.test_body')).tap do |message|
      message.delivery_method(:smtp, setting.delivery_options)
      message.deliver!
    end
  end
end
