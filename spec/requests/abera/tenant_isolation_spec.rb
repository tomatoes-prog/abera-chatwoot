require 'rails_helper'

RSpec.describe Abera::TenantMiddleware do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let!(:subscription) do
    Abera::Subscription.create!(account: account, subscription_id: 'sub-one', customer_id: 'customer-one',
                                service_host: 'one.example.test', tier: 'lite', state: 'active', activated_at: Time.current)
  end
  let(:app) { ->(_env) { [200, { 'Content-Type' => 'text/plain' }, ['OK']] } }
  let(:middleware) { described_class.new(app) }

  around { |example| with_modified_env(ABERA_MANAGED: 'true') { example.run } }

  it 'rejects a different account even if the URL is otherwise valid' do
    response = middleware.call(Rack::MockRequest.env_for("https://one.example.test/app/accounts/#{other_account.id}/dashboard"))
    expect(response.first).to eq(404)
  end

  it 'rejects another account when its identifier is percent encoded' do
    encoded = other_account.id.to_s.bytes.map { |byte| format('%%%02X', byte) }.join
    response = middleware.call(Rack::MockRequest.env_for("https://one.example.test/api/v1/accounts/#{encoded}/conversations"))
    expect(response.first).to eq(404)
  end

  it 'rejects an unknown service domain' do
    response = middleware.call(Rack::MockRequest.env_for('https://unknown.example.test/app'))
    expect(response.first).to eq(404)
  end

  it 'blocks installation onboarding and global administration' do
    %w[/installation/onboarding /super_admin /platform/api/v1/accounts].each do |path|
      response = middleware.call(Rack::MockRequest.env_for("https://one.example.test#{path}"))
      expect(response.first).to eq(404)
    end
  end

  it 'blocks a suspended account while its neighbor stays available' do
    Abera::Subscription.create!(account: other_account, subscription_id: 'sub-two', customer_id: 'customer-two',
                                service_host: 'two.example.test', tier: 'lite', state: 'active')
    subscription.update!(state: 'suspended')
    expect(middleware.call(Rack::MockRequest.env_for('https://one.example.test/app')).first).to eq(402)
    expect(middleware.call(Rack::MockRequest.env_for('https://two.example.test/app')).first).to eq(200)
  end

  it 'rejects a blob from another subscription on both original and variant routes' do
    blob = ActiveStorage::Blob.create_before_direct_upload!(filename: 'private.txt', byte_size: 1, checksum: 'ndTkYSaMgDT1yFZOFVxnpg==',
                                                           content_type: 'text/plain', metadata: { abera_subscription_id: 'sub-one' })
    blob.update!(metadata: { abera_subscription_id: 'sub-two' })
    %w[blobs representations].each do |kind|
      path = "/rails/active_storage/#{kind}/redirect/#{blob.signed_id}/file.txt"
      expect(middleware.call(Rack::MockRequest.env_for("https://one.example.test#{path}")).first).to eq(404)
    end
  end
end
