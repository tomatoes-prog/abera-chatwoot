require 'rails_helper'

RSpec.describe Abera::MessageDurability do
  let(:account) { create(:account) }
  let!(:subscription) do
    Abera::Subscription.create!(account: account, subscription_id: 'message-one', customer_id: 'owner-one',
                               service_host: 'message.example.test', tier: 'essential', state: 'active')
  end
  let(:conversation) { create(:conversation, account: account) }
  let(:redis) { Redis.new(Redis::Config.app) }

  before { allow(Redis::Alfred).to receive(:with).and_yield(redis) }

  after do
    redis.scan_each(match: 'abera:message-one:*') { |key| redis.del(key) }
    redis.close
  end

  it 'stores exactly one reply intent before the message transaction commits' do
    message = create(:message, account: account, conversation: conversation, inbox: conversation.inbox, message_type: :outgoing)
    replies = subscription.durable_jobs.where(job_class: 'SendReplyJob')
    expect(replies.count).to eq(1)
    expect(replies.first.arguments.fetch('arguments')).to eq([message.id])
  end

  it 'rolls back the delivery intent when the message transaction rolls back' do
    message_id = nil
    ApplicationRecord.transaction(requires_new: true) do
      message = create(:message, account: account, conversation: conversation, inbox: conversation.inbox, message_type: :outgoing)
      message_id = message.id
      expect(subscription.durable_jobs.where(job_class: 'SendReplyJob').count).to eq(1)
      raise ActiveRecord::Rollback
    end
    expect(Message.exists?(message_id)).to be(false)
    expect(subscription.durable_jobs.where(job_class: 'SendReplyJob')).to be_empty
  end
end
