class Abera::SmtpSetting < ApplicationRecord
  self.table_name = 'abera_smtp_settings'

  belongs_to :account, inverse_of: :abera_smtp_setting
  encrypts :password

  validates :address, :username, :password, :sender, presence: true
  validates :port, numericality: { only_integer: true, greater_than: 0, less_than: 65_536 }
  validates :sender, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :authentication, inclusion: { in: %w[login plain cram_md5] }
  validates :security, inclusion: { in: %w[starttls ssl] }

  def delivery_options
    {
      address: address, port: port, user_name: username, password: password,
      authentication: authentication.to_sym, enable_starttls: security == 'starttls',
      enable_starttls_auto: security == 'starttls', ssl: security == 'ssl',
      openssl_verify_mode: 'peer', open_timeout: 5, read_timeout: 10
    }
  end
end
