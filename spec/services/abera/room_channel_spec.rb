require 'rails_helper'

RSpec.describe RoomChannel, type: :channel do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:managed) do
    Abera::Subscription.create!(account: account, subscription_id: 'cable-one', customer_id: 'owner',
                                service_host: 'cable.example.test', tier: 'essential', state: 'active')
  end
  let(:message) { { 'event' => 'message.created', 'data' => { 'account_id' => account.id } } }

  before do
    stub_connection(abera_subscription_id: managed.id)
    subscribe(user_id: user.id, pubsub_token: user.pubsub_token, account_id: account.id)
  end

  it 'delivers to a member using streams scoped to its subscription' do
    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from("abera:cable-one:#{user.pubsub_token}")
    expect(subscription).to have_stream_from("abera:cable-one:account_#{account.id}")
    expect(subscription).to receive(:transmit).with(message)
    subscription.send(:abera_transmit, message)
  end

  it 'stops an existing connection when the user loses its membership' do
    AccountUser.where(account_id: account.id, user_id: user.id).delete_all
    expect(subscription).not_to receive(:transmit).with(message)
    subscription.send(:abera_transmit, message)
    expect(subscription).to be_rejected
    expect(subscription.streams).to be_empty
  end

  it 'stops an existing connection when its subscription is suspended' do
    managed.update!(state: 'suspended')
    expect(subscription).not_to receive(:transmit).with(message)
    subscription.send(:abera_transmit, message)
    expect(subscription).to be_rejected
    expect(subscription.streams).to be_empty
  end
end
