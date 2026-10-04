class Abera::ActivationsController < ApplicationController
  before_action :ensure_managed_subscription
  before_action :verify_authenticity_token, only: :create

  def show
    render :show, layout: false
  end

  def create
    subscription = Abera::Current.subscription
    subscription.with_lock do
      validate_activation_token!(subscription)
      user = activation_user(subscription)
      complete_activation(subscription, user) if user
    end
    redirect_to '/app/login' unless performed?
  rescue ActiveRecord::RecordInvalid => e
    @error = e.record.errors.full_messages.to_sentence
    render :show, status: :unprocessable_entity, layout: false
  end

  private

  def validate_activation_token!(subscription)
    token = Digest::SHA256.hexdigest(params.require(:token))
    valid = subscription.activation_token_digest.present? &&
            ActiveSupport::SecurityUtils.secure_compare(subscription.activation_token_digest, token)
    raise ActiveRecord::RecordNotFound unless valid && subscription.activation_consumed_at.nil? && subscription.state == 'pending'
  end

  def activation_user(subscription)
    email = subscription.admin_email.presence || params.require(:email).strip.downcase
    user = User.from_email(email)
    if user
      return user if authenticated_existing_user?(user)

      @error = I18n.t('abera.activation.authentication_required')
      render :show, status: :unauthorized, layout: false
      return
    end
    user = User.new(email: email, name: params.require(:name), password: params.require(:password))
    user.skip_confirmation!
    user.save!
    user
  end

  def authenticated_existing_user?(user)
    return true if current_user == user
    return false unless user.valid_password?(params[:password].to_s)
    return true unless user.mfa_enabled?

    Mfa::AuthenticationService.new(user: user, otp_code: params[:otp_code], backup_code: params[:backup_code]).authenticate
  end

  def complete_activation(subscription, user)
    AccountUser.create!(account: subscription.account, user: user, role: :administrator)
    subscription.update!(state: 'active', activation_token_digest: nil, activation_consumed_at: Time.current, activated_at: Time.current)
  end

  def ensure_managed_subscription
    head :not_found unless Abera.enabled? && Abera::Current.subscription
  end
end
