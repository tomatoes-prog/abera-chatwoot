require 'rails_helper'

RSpec.describe Abera::BroadcastIsolation do
  let(:account) { create(:account) }
  let(:neighbor) { create(:account) }
  let!(:subscription) do
    Abera::Subscription.create!(account: account, subscription_id: 'broadcast-one', customer_id: 'owner-one',
                               service_host: 'broadcast.example.test', tier: 'essential', state: 'active')
  end
  let!(:neighbor_subscription) do
    Abera::Subscription.create!(account: neighbor, subscription_id: 'broadcast-two', customer_id: 'owner-two',
                               service_host: 'neighbor.example.test', tier: 'essential', state: 'active')
  end

  it 'separates deliveries even when both accounts use the same user pubsub token' do
    expect(ActionCable.server).to receive(:broadcast).with('abera:broadcast-one:shared-token',
                                                          { event: 'message.created', data: { account_id: account.id } })
    expect(ActionCable.server).to receive(:broadcast).with('abera:broadcast-two:shared-token',
                                                          { event: 'message.created', data: { account_id: neighbor.id } })
    ActionCableBroadcastJob.perform_now(['shared-token'], 'message.created', { account_id: account.id })
    ActionCableBroadcastJob.perform_now(['shared-token'], 'message.created', { account_id: neighbor.id })
  end

  it 'stops broadcasts from a suspended account' do
    subscription.update!(state: 'suspended')
    expect(ActionCable.server).not_to receive(:broadcast)
    ActionCableBroadcastJob.perform_now(['shared-token'], 'message.created', { account_id: account.id })
  end
end
