class Abera::TenantMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless Abera.enabled?

    request = Rack::Request.new(env)
    path = Rack::Utils.unescape_path(request.path)
    return @app.call(env) if path == '/health'
    return response(404, 'Not found') if path.start_with?('/installation', '/super_admin', '/platform')

    subscription = Abera::Subscription.find_by(service_host: request.host.downcase)
    return response(404, 'Unknown service') unless subscription

    Abera::TenantLock.with_access(subscription) { |managed| serve(env, request, path, managed) }
  ensure
    if Abera.enabled?
      Abera::Current.reset
      Current.reset
      ActiveStorage::Current.reset
    end
  end

  private

  def serve(env, request, path, subscription)
    Abera::Current.subscription = subscription
    Current.account = subscription.account
    ActiveStorage::Current.url_options = { host: subscription.service_host, protocol: 'https' }
    denied = route_error(request, path, subscription) || state_error(path, subscription) ||
             quota_error(path, subscription) || attachment_error(path, subscription)
    denied || @app.call(env)
  end

  def route_error(request, path, subscription)
    account_path = path.match(%r{\A/(?:api/v[12]|app)/accounts/(\d+)(?:/|\z)})
    return response(404, 'Unknown account') if account_path && account_path[1].to_i != subscription.account_id
    return response(403, 'Use the service activation link') if request.post? && ['/auth', '/api/v1/accounts'].include?(path)

    nil
  end

  def state_error(path, subscription)
    case subscription.state
    when 'suspended', 'archived' then response(402, 'Service is suspended')
    when 'quiescing' then response(503, 'Service is undergoing maintenance')
    when 'pending'
      activation = path.start_with?('/abera/activate', '/auth/', '/app/login', '/app/auth', '/assets/', '/vite/')
      response(403, 'Service activation is required') unless activation
    end
  end

  def quota_error(path, subscription)
    return unless path.start_with?('/api/', '/webhooks/') && !Abera::RateLimit.allowed?(subscription, 'requests', 300)

    return response(429, 'Request limit exceeded', 'Retry-After' => '60')
  end

  def attachment_error(path, subscription)
    return unless path.start_with?('/rails/active_storage/blobs/', '/rails/active_storage/representations/')

    signed_id = path.split('/')[5]
    blob = ActiveStorage::Blob.find_signed(signed_id) if signed_id
    response(404, 'Unknown attachment') unless blob && Abera::BlobAccess.allowed?(blob, subscription)
  end

  def response(status, message, headers = {})
    [status, { 'Content-Type' => 'application/json', 'Cache-Control' => 'no-store' }.merge(headers), [JSON.generate(error: message)]]
  end
end
