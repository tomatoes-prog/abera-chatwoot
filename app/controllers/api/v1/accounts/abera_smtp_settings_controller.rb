class Api::V1::Accounts::AberaSmtpSettingsController < Api::V1::Accounts::BaseController
  before_action :check_admin_authorization?
  before_action { head :not_found unless Abera.enabled? }

  def show
    render json: public_settings
  end

  def update
    raise 'Active Record encryption is required for managed SMTP' unless Chatwoot.encryption_configured?

    setting = Current.account.abera_smtp_setting || Current.account.build_abera_smtp_setting
    attributes = setting_params.to_h
    attributes.delete('password') if attributes['password'].blank? && setting.persisted?
    setting.update!(attributes)
    render json: public_settings
  end

  def test
    raise ActiveRecord::RecordNotFound unless Current.account.abera_smtp_setting

    job = Abera::SmtpTestJob.perform_later(Current.account.id, current_user.id)
    render json: { jobId: job.job_id }, status: :accepted
  end

  def test_status
    work = Current.account.abera_subscription.durable_jobs.where(job_class: 'Abera::SmtpTestJob')
                  .where("arguments ->> 'job_id' = ? AND arguments -> 'arguments' ->> 1 = ?", params.require(:jobId), current_user.id.to_s).take!
    render json: { state: work.state }
  end

  private

  def setting_params
    params.require(:smtp).permit(:address, :port, :username, :password, :sender, :authentication, :security)
  end

  def public_settings
    setting = Current.account.abera_smtp_setting
    return { configured: false } unless setting

    setting.attributes.slice('address', 'port', 'username', 'sender', 'authentication', 'security').merge(configured: true)
  end
end
