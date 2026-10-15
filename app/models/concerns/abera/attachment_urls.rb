module Abera::AttachmentUrls
  def default_url_options
    return super unless Abera.enabled?

    url = URI.parse(Rails.application.config.x[:account_frontend_url_resolver].call(account))
    super.merge(host: url.host, protocol: url.scheme, port: url.port)
  end

  def download_url
    return super unless Abera.enabled?
    return '' unless file.attached?

    ActiveStorage::Current.set(url_options: default_url_options) { file.blob.url }
  end

  private

  def inline_audio_url
    return super unless Abera.enabled?
    return '' unless file.attached?

    Rails.application.routes.url_helpers.rails_storage_redirect_url(file, disposition: 'inline', **default_url_options)
  end
end
