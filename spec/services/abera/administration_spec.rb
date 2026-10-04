require 'rails_helper'

RSpec.describe Abera::Administration do
  let(:command) do
    { 'operationId' => 'create-one', 'subscriptionId' => 'sub-one', 'customerId' => 'customer-one', 'action' => 'CREATE',
      'serviceHost' => 'one.example.test', 'tier' => 'essential' }
  end

  around { |example| with_modified_env(ABERA_MANAGED: 'true') { example.run } }

  it 'creates a pending account and returns the same activation credential on retry' do
    result = described_class.new(command).run
    retry_result = described_class.new(command).run
    subscription = Abera::Subscription.find_by!(subscription_id: 'sub-one')
    expect(subscription.state).to eq('pending')
    expect(subscription.account.locale).to eq('es')
    expect(subscription.account.account_users).to be_empty
    expect(retry_result).to eq(result)
    expect(result.fetch('credentials').fetch('activationUrl')).to start_with('https://one.example.test/abera/activate?token=')
    expect(Abera::Subscription.where(subscription_id: 'sub-one').count).to eq(1)
  end

  it 'creates an account administrator with credentials when a new email is provided' do
    result = described_class.new(command.merge('adminEmail' => 'owner@example.test')).run
    subscription = Abera::Subscription.find_by!(subscription_id: 'sub-one')
    user = User.from_email('owner@example.test')
    expect(subscription).to be_usable
    expect(subscription.account.account_users.find_by!(user: user)).to be_administrator
    expect(user.valid_password?(result.fetch('credentials').fetch('adminPassword'))).to be(true)
    expect(user).not_to be_a(SuperAdmin)
  end

  it 'requires activation of an existing email and preserves its password' do
    user = create(:user, email: 'owner@example.test')
    original_password = user.encrypted_password
    result = described_class.new(command.merge('adminEmail' => user.email)).run
    expect(result.fetch('credentials')).to have_key('activationUrl')
    expect(user.reload.encrypted_password).to eq(original_password)
    expect(Abera::Subscription.find_by!(subscription_id: 'sub-one').account.account_users).to be_empty
  end

  it 'keeps an unconsumed activation usable after suspension and reactivation' do
    described_class.new(command).run
    subscription = Abera::Subscription.find_by!(subscription_id: 'sub-one')
    token_digest = subscription.activation_token_digest
    described_class.new(command.merge('operationId' => 'suspend-one', 'action' => 'SUSPEND')).run
    result = described_class.new(command.merge('operationId' => 'reactivate-one', 'action' => 'REACTIVATE')).run
    expect(result.fetch('state')).to eq('pending')
    expect(subscription.reload.activation_token_digest).to eq(token_digest)
    expect(subscription.account.reload).to be_active
  end

  it 'rejects another owner before returning a previous credential receipt' do
    described_class.new(command).run
    expect do
      described_class.new(command.merge('customerId' => 'another-owner')).run
    end.to raise_error(RuntimeError, 'Subscription owner mismatch')
  end
end
