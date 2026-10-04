class Abera::InstallationSetup
  def self.run
    raise 'Managed mode is required' unless Abera.enabled?

    ConfigLoader.new.process
    values = { 'INSTALLATION_NAME' => ENV.fetch('INSTALLATION_NAME'), 'BRAND_NAME' => ENV.fetch('INSTALLATION_NAME'),
               'ENABLE_ACCOUNT_SIGNUP' => false, 'CREATE_NEW_ACCOUNT_FROM_DASHBOARD' => false }
    values.each do |name, value|
      InstallationConfig.find_by!(name: name).update!(value: value)
    end
    Redis::Alfred.delete(Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING)
    GlobalConfig.clear_cache
  end
end
