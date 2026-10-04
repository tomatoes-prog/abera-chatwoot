RSpec.configure do |config|
  config.define_derived_metadata(file_path: %r{/spec/(requests|services)/abera/}) do |metadata|
    metadata[:abera_managed] = true
  end

  config.around(:each, :abera_managed) do |example|
    original_resolver = Rails.application.config.x[:account_frontend_url_resolver]
    Rails.application.config.x[:account_frontend_url_resolver] = lambda do |account|
      raise ArgumentError, 'An account is required to generate a managed service URL' unless account

      Abera::Subscription.find_by!(account_id: account.id).service_url
    end
    with_modified_env(ABERA_MANAGED: 'true') { example.run }
  ensure
    Rails.application.config.x[:account_frontend_url_resolver] = original_resolver
    Abera::Current.reset
    Current.reset
  end
end
