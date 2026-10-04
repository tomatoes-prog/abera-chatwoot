require 'rails_helper'

RSpec.describe Abera::BlobAccess do
  let(:account) { create(:account) }
  let(:neighbor) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:subscription) do
    Abera::Subscription.create!(account: account, subscription_id: 'avatar-owner', customer_id: 'owner',
                                service_host: 'avatar.example.test', tier: 'essential', state: 'active')
  end
  let(:blob) do
    ActiveStorage::Blob.create_before_direct_upload!(filename: 'avatar.png', byte_size: 1, checksum: 'ndTkYSaMgDT1yFZOFVxnpg==',
                                                     content_type: 'image/png', metadata: { abera_subscription_id: 'other-subscription' })
  end

  it 'allows the shared profile avatar only while its user belongs to this account' do
    with_modified_env(ABERA_MANAGED: 'false') do
      ActiveStorage::Attachment.create!(name: 'avatar', record: user, blob: blob)
    end
    expect(described_class.allowed?(blob, subscription)).to be(true)
    AccountUser.where(account: account, user: user).delete_all
    expect(described_class.allowed?(blob, subscription)).to be(false)
  end

  it 'rejects an image that is also an attachment to account content' do
    with_modified_env(ABERA_MANAGED: 'false') do
      ActiveStorage::Attachment.create!(name: 'avatar', record: user, blob: blob)
      ActiveStorage::Attachment.create!(name: 'avatar', record: create(:contact, account: neighbor), blob: blob)
    end
    expect(described_class.allowed?(blob, subscription)).to be(false)
  end
end
