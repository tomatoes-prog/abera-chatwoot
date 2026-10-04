module Abera::DirectUploadIsolation
  extend ActiveSupport::Concern

  included do
    include DeviseTokenAuth::Concerns::SetUserByToken
    before_action :abera_authorize_direct_upload
  end

  private

  def abera_authorize_direct_upload
    return unless Abera.enabled? && instance_of?(ActiveStorage::DirectUploadsController)

    subscription = Abera::Current.subscription
    head :unauthorized unless current_user && subscription&.usable? && subscription.account.users.exists?(current_user.id)
  end
end
