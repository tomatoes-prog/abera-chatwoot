class Abera::Administration
  STATE_ACTIONS = { 'SUSPEND' => 'suspended', 'REACTIVATE' => 'active', 'QUIESCE' => 'quiescing' }.freeze
  METHOD_ACTIONS = { 'CREATE' => :create_account, 'DROP' => :drop_account, 'RESTORE' => :restore_account,
                     'STATUS' => :status, 'CHECK' => :check, 'CHECK_IMPORT' => :check_import }.freeze
  def initialize(command)
    @command = command.deep_stringify_keys
  end

  def run
    raise 'Managed mode and encryption are required' unless Abera.enabled? && Chatwoot.encryption_configured?

    result = ApplicationRecord.transaction do
      lock_id = Digest::SHA256.hexdigest("abera-operation:#{@command.fetch('subscriptionId')}")[0, 15].to_i(16)
      ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(#{lock_id})")
      managed = owned_subscription
      existing = previous_receipt(managed)
      next existing.result.merge('credentials' => existing.credentials) if existing

      lock_subscription!(managed) if managed
      Abera::Current.administrative_operation = true
      record_result(execute_action)
    end
    @committed = true
    result
  ensure
    @restore_operation&.cleanup_partial unless @committed
    Abera::Current.reset
    Current.reset
  end

  private

  def record_result(result)
    result = result.merge('customerId' => @command.fetch('customerId'))
    receipt = Abera::OperationReceipt.create!(operation_id: @command.fetch('operationId'), subscription_id: @command.fetch('subscriptionId'),
                                              action: @command.fetch('action'), result: result.except('credentials'),
                                              credentials: result['credentials'])
    receipt.result.merge('credentials' => receipt.credentials)
  end

  def owned_subscription
    managed = Abera::Subscription.find_by(subscription_id: @command.fetch('subscriptionId'))
    raise 'Subscription owner mismatch' if managed && managed.customer_id != @command.fetch('customerId')

    managed
  end

  def previous_receipt(managed)
    existing = Abera::OperationReceipt.find_by(operation_id: @command.fetch('operationId'), action: @command.fetch('action'))
    raise 'Operation receipt subscription mismatch' if existing && existing.subscription_id != @command.fetch('subscriptionId')

    if existing && !managed
      raise 'The operation subscription no longer exists' unless %w[DROP CHECK CHECK_IMPORT].include?(existing.action)
      raise 'Subscription owner mismatch' unless existing.result.fetch('customerId') == @command.fetch('customerId')
    end

    existing
  end

  def lock_subscription!(managed)
    raise 'Account changed since the operation was prepared' if @command.key?('accountId') && managed.account_id != @command.fetch('accountId').to_i

    Abera::TenantLock.exclusive!(managed)
    work_lock = Digest::SHA256.hexdigest("abera-jobs:#{managed.id}")[0, 15].to_i(16)
    ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(#{work_lock})")
  end

  def execute_action
    state = STATE_ACTIONS[@command.fetch('action')]
    return change_state(state) if state

    method = METHOD_ACTIONS.fetch(@command.fetch('action')) { raise "Unsupported administration action: #{@command.fetch('action')}" }
    send(method)
  end

  def subscription
    @subscription ||= Abera::Subscription.find_by!(subscription_id: @command.fetch('subscriptionId'))
    raise 'Subscription owner mismatch' unless @subscription.customer_id == @command.fetch('customerId')

    @subscription
  end

  def create_account
    raise 'Subscription already exists without its creation receipt' if Abera::Subscription.exists?(subscription_id: @command.fetch('subscriptionId'))

    account = Account.create!(name: @command.fetch('displayName', 'Abera'), locale: 'es', reporting_timezone: 'America/Bogota')
    Current.account = account
    token = SecureRandom.urlsafe_base64(32)
    @subscription = create_subscription(account, token)
    credentials = { 'serviceUrl' => subscription.service_url, 'activationUrl' => "#{subscription.service_url}/abera/activate?token=#{token}" }
    credentials = create_administrator(account) if subscription.admin_email.present? && !User.from_email(subscription.admin_email)
    status.merge('credentials' => credentials)
  end

  def create_subscription(account, token)
    Abera::Subscription.create!(account: account, subscription_id: @command.fetch('subscriptionId'),
                                customer_id: @command.fetch('customerId'), service_host: @command.fetch('serviceHost'),
                                tier: @command.fetch('tier'), admin_email: @command['adminEmail'].presence,
                                activation_token_digest: Digest::SHA256.hexdigest(token))
  end

  def create_administrator(account)
    password = "Aa1!#{SecureRandom.urlsafe_base64(24)}"
    user = User.new(email: subscription.admin_email, name: @command['adminName'].presence || subscription.admin_email, password: password)
    user.skip_confirmation!
    user.save!
    AccountUser.create!(account: account, user: user, role: :administrator)
    subscription.update!(state: 'active', activated_at: Time.current, activation_token_digest: nil, activation_consumed_at: Time.current)
    { 'serviceUrl' => subscription.service_url, 'adminEmail' => user.email, 'adminPassword' => password }
  end

  def change_state(state)
    state = 'pending' if state == 'active' && subscription.activated_at.nil? && subscription.activation_token_digest.present?
    subscription.update!(state: state)
    subscription.account.update!(status: %w[active pending].include?(state) ? :active : :suspended)
    status
  end

  def status
    { 'subscriptionId' => subscription.subscription_id, 'accountId' => subscription.account_id,
      'state' => subscription.state, 'serviceHost' => subscription.service_host, 'tier' => subscription.tier }
  end

  def check
    owned_subscription ? status : { 'subscriptionId' => @command.fetch('subscriptionId'), 'state' => 'absent' }
  end

  def drop_account
    return Abera::AccountRemoval.new(subscription).run if owned_subscription

    receipt = Abera::OperationReceipt.where(subscription_id: @command.fetch('subscriptionId'), action: 'DROP').order(id: :desc).first!
    expected = @command.slice('customerId', 'accountId')
    raise 'Removal receipt ownership mismatch' unless expected.all? { |key, value| receipt.result.fetch(key) == value }

    receipt.result
  end

  def restore_account
    raise 'Destination subscription already exists' if @command['requireEmpty'] && owned_subscription

    @restore_operation = Abera::AccountRestore.new(@command, existing: owned_subscription)
    @restore_operation.run
  end

  def check_import
    snapshot = Abera::BackupReader.new(@command).snapshot
    { 'subscriptionId' => @command.fetch('subscriptionId'), 'eligible' => Abera::ImportCompatibility.eligible?(snapshot) }
  end
end
