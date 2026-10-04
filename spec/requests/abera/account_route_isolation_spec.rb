require 'rails_helper'

RSpec.describe Abera::AccountRouteIsolation do
  let(:account) { create(:account) }
  let(:neighbor) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:rate_limit_redis) { Redis.new(Redis::Config.app) }

  before do
    # Native test mode uses MockRedis, which cannot execute the atomic Lua quota.
    allow(Redis::Alfred).to receive(:with).and_yield(rate_limit_redis)
    Abera::Subscription.create!(account: account, subscription_id: 'route-one', customer_id: 'owner-one',
                                service_host: 'one.example.test', tier: 'essential', state: 'active')
    Abera::Subscription.create!(account: neighbor, subscription_id: 'route-two', customer_id: 'owner-two',
                                service_host: 'two.example.test', tier: 'essential', state: 'active')
    AccountUser.create!(account: neighbor, user: user, role: :administrator)
    host! 'one.example.test'
  end

  after do
    rate_limit_redis.scan_each(match: 'abera:route-one:requests:*') { |key| rate_limit_redis.del(key) }
    rate_limit_redis.close
  end

  it 'allows an authenticated owner to retrieve this domain account' do
    get "/api/v1/accounts/#{account.id}", headers: user.create_new_auth_token, as: :json,
                                          env: { 'action_dispatch.show_exceptions' => :none }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('id')).to eq(account.id)
  end

  it 'rejects changes to another membership in the global profile API' do
    membership = neighbor.account_users.find_by!(user: user)
    original = membership.auto_offline
    post '/api/v1/profile/auto_offline', params: { profile: { account_id: neighbor.id, auto_offline: !original } },
                                         headers: user.create_new_auth_token, as: :json,
                                         env: { 'action_dispatch.show_exceptions' => :none }
    expect(response).to have_http_status(:not_found)
    expect(membership.reload.auto_offline).to eq(original)
  end

  it 'lists only the membership belonging to the current service domain' do
    get '/api/v1/profile', headers: user.create_new_auth_token, as: :json,
                           env: { 'action_dispatch.show_exceptions' => :none }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('accounts').map { |membership| membership.fetch('id') }).to eq([account.id])
    expect(response.parsed_body.fetch('account_id')).to eq(account.id)
  end

  it 'rejects a profile request from a user with no membership on this domain' do
    outsider = create(:user, account: neighbor)
    get '/api/v1/profile', headers: outsider.create_new_auth_token, as: :json,
                           env: { 'action_dispatch.show_exceptions' => :none }
    expect(response).to have_http_status(:not_found)
  end
end
