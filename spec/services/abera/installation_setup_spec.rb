require 'rails_helper'

RSpec.describe Abera::InstallationSetup do
  around { |example| with_modified_env(INSTALLATION_NAME: 'Abera') { example.run } }

  it 'sets native branding and closes only the global installation onboarding' do
    Redis::Alfred.set(Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING, 'true')
    described_class.run
    expect(GlobalConfig.get_value('INSTALLATION_NAME')).to eq('Abera')
    expect(GlobalConfig.get_value('BRAND_NAME')).to eq('Abera')
    expect(GlobalConfigService.account_signup_enabled?).to be(false)
    expect(GlobalConfig.get_value('CREATE_NEW_ACCOUNT_FROM_DASHBOARD')).to be(false)
    expect(Redis::Alfred.get(Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING)).to be_nil
  ensure
    Redis::Alfred.delete(Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING)
    GlobalConfig.clear_cache
  end
end
