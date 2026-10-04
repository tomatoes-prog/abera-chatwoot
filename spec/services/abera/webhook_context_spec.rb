require 'rails_helper'

RSpec.describe Abera::WebhookContext do
  let(:account) { create(:account) }
  let(:neighbor) { create(:account) }
  let!(:subscription) do
    Abera::Subscription.create!(account: account, subscription_id: 'webhook-one', customer_id: 'owner-one',
                               service_host: 'webhook.example.test', tier: 'essential', state: 'active')
  end
  let!(:neighbor_subscription) do
    Abera::Subscription.create!(account: neighbor, subscription_id: 'webhook-two', customer_id: 'owner-two',
                               service_host: 'neighbor.example.test', tier: 'essential', state: 'active')
  end

  after do
    Abera::Current.reset
    Current.reset
  end

  it 'resolves a Telegram event from its actual channel' do
    channel = create(:channel_telegram, account: account, bot_token: 'own-bot')
    job = Webhooks::TelegramEventsJob.new({ 'bot_token' => channel.bot_token, 'update_id' => 100 })
    expect(described_class.account(job)).to eq(account)
  end

  it 'rejects a foreign bot before accepting any durable work on the current domain' do
    channel = create(:channel_telegram, account: neighbor, bot_token: 'neighbor-bot')
    Abera::Current.subscription = subscription
    Current.account = account
    original = subscription.durable_jobs.count
    expect do
      Webhooks::TelegramEventsJob.perform_later({ 'bot_token' => channel.bot_token, 'update_id' => 100 })
    end.to raise_error(ActiveRecord::RecordNotFound)
    expect(subscription.durable_jobs.count).to eq(original)
  end

  it 'rejects an unknown channel without acknowledging its event as queued' do
    job = Webhooks::TelegramEventsJob.new({ 'bot_token' => 'unknown-bot', 'update_id' => 100 })
    expect { described_class.account(job) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it 'checks every WhatsApp change and rejects a batch spanning two accounts' do
    payload = { object: 'whatsapp_business_account', entry: [{ changes: [{ value: {} }, { value: {} }] }] }
    job = Webhooks::WhatsappEventsJob.new(payload)
    allow(job).to receive(:find_channel_from_whatsapp_business_payload).and_return(double(account: account), double(account: neighbor))
    expect { described_class.account(job) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it 'rejects a WhatsApp batch when any channel cannot be resolved' do
    payload = { object: 'whatsapp_business_account', entry: [{ changes: [{ value: {} }, { value: {} }] }] }
    job = Webhooks::WhatsappEventsJob.new(payload)
    allow(job).to receive(:find_channel_from_whatsapp_business_payload).and_return(double(account: account), nil)
    expect { described_class.account(job) }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
