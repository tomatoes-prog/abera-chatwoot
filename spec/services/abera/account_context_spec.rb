require 'rails_helper'

RSpec.describe Abera::AccountContext do
  let(:account) { create(:account) }
  let(:neighbor) { create(:account) }

  it 'resolves account parameters inside serialized mail arguments' do
    expect(described_class.resolve([{ params: { account: account } }, { args: ['token'] }])).to eq(account)
    expect(described_class.resolve([{ portal: create(:portal, account: account) }])).to eq(account)
  end

  it 'rejects arguments containing resources from different accounts' do
    expect { described_class.resolve([account, neighbor]) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it 'does not infer resource ownership from a shared user current membership' do
    user = create(:user, account: account)
    AccountUser.create!(account: neighbor, user: user, role: :agent)
    Current.account = neighbor
    expect(described_class.resolve([account, user])).to eq(account)
  ensure
    Current.reset
  end
end
