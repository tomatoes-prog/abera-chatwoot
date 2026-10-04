require 'rails_helper'

RSpec.describe Abera::FacebookDeliveryIsolation do
  let(:account) { create(:account) }
  let(:neighbor) { create(:account) }
  let(:channel) { create(:channel_facebook_page, account: account, inbox: build(:inbox, account: account)) }
  let(:inbox) { channel.inbox }
  let(:subscription) do
    Abera::Subscription.create!(account: account, subscription_id: 'facebook-own', customer_id: 'owner',
                                service_host: 'facebook.example.test', tier: 'essential', state: 'active')
  end

  before { stub_request(:post, /graph\.facebook\.com/).to_return(body: '{}') }

  after { Abera::Current.reset }

  it 'updates only the conversation in the webhook channel when another inbox has the same sender ID' do
    foreign_conversation = create(:conversation, account: neighbor)
    create(:contact_inbox, inbox: foreign_conversation.inbox, contact: foreign_conversation.contact, source_id: 'shared-sender')
    own_conversation = create(:conversation, account: account, inbox: inbox)
    create(:contact_inbox, inbox: inbox, contact: own_conversation.contact, source_id: 'shared-sender')
    Abera::Current.subscription = subscription
    parser = instance_double(Integrations::Facebook::MessageParser, sender_id: 'shared-sender', recipient_id: channel.page_id,
                                                                  delivery_watermark: 100, read_watermark: nil)
    expect(Conversations::UpdateMessageStatusJob).to receive(:perform_later).with(own_conversation.id, anything, :delivered)
    Integrations::Facebook::DeliveryStatus.new(params: parser).perform
  end

  it 'rejects a delivery callback whose channel belongs to a different subscription' do
    inbox
    other = Abera::Subscription.create!(account: neighbor, subscription_id: 'facebook-other', customer_id: 'neighbor',
                                        service_host: 'other.example.test', tier: 'essential', state: 'active')
    Abera::Current.subscription = other
    parser = instance_double(Integrations::Facebook::MessageParser, sender_id: 'shared-sender', recipient_id: channel.page_id)
    expect { Integrations::Facebook::DeliveryStatus.new(params: parser).perform }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
