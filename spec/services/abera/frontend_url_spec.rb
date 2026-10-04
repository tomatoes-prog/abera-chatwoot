require 'rails_helper'

RSpec.describe ChatwootApp do
  let(:account) { create(:account) }
  let(:neighbor) { create(:account) }

  before do
    Abera::Subscription.create!(account: account, subscription_id: 'url-one', customer_id: 'owner-one',
                               service_host: 'one.example.test', tier: 'essential', state: 'active')
    Abera::Subscription.create!(account: neighbor, subscription_id: 'url-two', customer_id: 'owner-two',
                               service_host: 'two.example.test', tier: 'essential', state: 'active')
  end

  after { Current.reset }

  it 'generates background URLs from the resource account despite another request context' do
    Current.account = neighbor
    channel = create(:channel_widget, account: account)
    conversation = create(:conversation, account: account)
    expect(channel.web_widget_script).to include('https://one.example.test')
    expect(channel.web_widget_script).not_to include('https://two.example.test')
    expect(conversation.csat_survey_link).to eq("https://one.example.test/survey/responses/#{conversation.uuid}")
  end

  it 'uses the current account for frontend configuration and refuses an unscoped managed URL' do
    Current.account = neighbor
    expect(described_class.frontend_url).to eq('https://two.example.test')
    Current.reset
    expect { described_class.frontend_url }.to raise_error(ArgumentError, /account is required/)
  end
end
