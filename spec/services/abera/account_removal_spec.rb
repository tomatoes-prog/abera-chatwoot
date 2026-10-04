require 'rails_helper'

RSpec.describe Abera::AccountRemoval do
  let(:account) { create(:account) }
  let(:neighbor) { create(:account) }
  let!(:conversation) { create(:conversation, account: account) }
  let!(:neighbor_conversation) { create(:conversation, account: neighbor) }
  let!(:message) { create(:message, account: account, conversation: conversation, inbox: conversation.inbox) }
  let!(:user) { create(:user, account: account, role: :administrator) }
  let!(:membership) { create(:account_user, account: neighbor, user: user) }
  let!(:subscription) do
    Abera::Subscription.create!(account: account, subscription_id: 'remove-one', customer_id: 'owner-one',
                                service_host: 'remove.example.test', tier: 'lite', state: 'quiescing')
  end
  let(:command) do
    { 'operationId' => 'drop-one', 'subscriptionId' => subscription.subscription_id, 'customerId' => 'owner-one',
      'accountId' => account.id, 'action' => 'DROP' }
  end

  around { |example| with_modified_env(ABERA_MANAGED: 'true') { example.run } }

  it 'removes just the account graph and retries from its durable receipt' do
    api_token = user.access_token.token
    result = Abera::Administration.new(command).run
    expect(result.fetch('state')).to eq('absent')
    expect(Account.exists?(account.id)).to be(false)
    expect(Conversation.exists?(conversation.id)).to be(false)
    expect(Message.exists?(message.id)).to be(false)
    expect(Abera::Subscription.exists?(subscription.id)).to be(false)
    expect(neighbor.reload.conversations).to include(neighbor_conversation)
    expect(membership.reload.user).to eq(user.reload)
    expect(user.access_token.reload.token).to eq(api_token)
    expect(Abera::Administration.new(command).run).to eq(result)
  end

  it 'rejects a foreign owner after deletion without disclosing the receipt' do
    Abera::Administration.new(command).run
    expect do
      Abera::Administration.new(command.merge('customerId' => 'foreign')).run
    end.to raise_error(RuntimeError, 'Subscription owner mismatch')
  end

  it 'refuses deletion while the account still accepts writes' do
    subscription.update!(state: 'active')
    expect { Abera::Administration.new(command).run }.to raise_error(RuntimeError, 'Account must be quiesced before removal')
    expect(account.reload.conversations).to include(conversation)
    expect(Abera::OperationReceipt.exists?(operation_id: 'drop-one')).to be(false)
  end

  it 'lets an operator retry cleanup using a new operation after the account is absent' do
    result = Abera::Administration.new(command).run
    retry_result = Abera::Administration.new(command.merge('operationId' => 'drop-retry')).run
    expect(retry_result.except('credentials')).to eq(result.except('credentials'))
    expect(Abera::OperationReceipt.exists?(operation_id: 'drop-retry')).to be(true)
    expect(neighbor.reload.conversations).to include(neighbor_conversation)
  end

  it 'rejects an old deletion command after the subscription is recreated' do
    original_command = command.dup
    Abera::Administration.new(original_command).run
    recreated = create(:account)
    Abera::Subscription.create!(account: recreated, subscription_id: 'remove-one', customer_id: 'owner-one',
                                service_host: 'remove.example.test', tier: 'professional', state: 'quiescing')
    expect do
      Abera::Administration.new(original_command.merge('operationId' => 'late-drop')).run
    end.to raise_error(RuntimeError, 'Account changed since the operation was prepared')
    expect(recreated.reload).to be_present
    expect(neighbor.reload.conversations).to include(neighbor_conversation)
  end
end
