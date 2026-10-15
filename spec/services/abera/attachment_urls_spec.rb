require 'rails_helper'

RSpec.describe Abera::AttachmentUrls do
  let(:account) { create(:account) }
  let!(:neighbor) { create(:account) }
  let(:message) { create(:message, account: account) }
  let!(:subscription) do
    Abera::Subscription.create!(account: account, subscription_id: 'attachment-owner', customer_id: 'owner',
                                service_host: 'owner.example.test', tier: 'essential', state: 'active')
  end

  around do |example|
    original_options = Rails.application.routes.default_url_options.dup
    Rails.application.routes.default_url_options.clear
    with_modified_env(ABERA_MANAGED: 'true') { example.run }
  ensure
    Rails.application.routes.default_url_options.replace(original_options)
    Abera::Current.reset
    Current.reset
  end

  it 'persists an inline file with ownership before attachment validation and charges its bytes once' do
    Abera::Current.subscription = subscription
    Current.account = account
    attachment = message.attachments.build(account: account, file_type: :file)
    attachment.file.attach(io: StringIO.new('private QA bytes'), filename: 'private.txt', content_type: 'text/plain')
    attachment.save!
    expect(attachment.file.blob.metadata['abera_subscription_id']).to eq(subscription.subscription_id)
    expect(subscription.reload.storage_reserved_bytes).to eq('private QA bytes'.bytesize)
    attachment.file.blob.save!
    expect(subscription.reload.storage_reserved_bytes).to eq('private QA bytes'.bytesize)
  end

  it 'rejects a signed existing blob owned by a different subscription' do
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new('other bytes'), filename: 'other.txt',
                                                  content_type: 'text/plain', metadata: { abera_subscription_id: 'neighbor' })
    Abera::Current.subscription = subscription
    Current.account = account
    attachment = message.attachments.build(account: account, file_type: :file)
    attachment.file.attach(blob.signed_id)
    expect { attachment.save! }.to raise_error(ActiveRecord::RecordNotSaved)
    expect(blob.reload.metadata['abera_subscription_id']).to eq('neighbor')
  end

  it 'generates a private file URL for its own account outside an HTTP request' do
    Abera::Current.subscription = subscription
    attachment = message.attachments.build(account: account, file_type: :file)
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new('private QA bytes'), filename: 'private.txt', content_type: 'text/plain')
    attachment.file.attach(blob)
    attachment.save!
    Abera::Current.reset
    expect(URI.parse(attachment.file_url).host).to eq(subscription.service_host)
    expect(URI.parse(attachment.file_url).scheme).to eq('https')
  end

  it 'keeps the owner URL when another account is current' do
    Abera::Current.subscription = subscription
    attachment = message.attachments.build(account: account, file_type: :file)
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new('private QA bytes'), filename: 'private.txt', content_type: 'text/plain')
    attachment.file.attach(blob)
    attachment.save!
    Abera::Current.subscription = Abera::Subscription.create!(account: neighbor, subscription_id: 'attachment-neighbor', customer_id: 'neighbor',
                                                              service_host: 'neighbor.example.test', tier: 'essential', state: 'active')
    expect(URI.parse(attachment.file_url).host).to eq(subscription.service_host)
  end

  it 'uses the owner host for audio redirects and background download URLs' do
    Abera::Current.subscription = subscription
    attachment = message.attachments.build(account: account, file_type: :audio)
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new('private audio bytes'), filename: 'audio.mp3', content_type: 'audio/mpeg')
    attachment.file.attach(blob)
    attachment.save!
    Abera::Current.reset
    ActiveStorage::Current.set(url_options: { host: 'neighbor.example.test', protocol: 'https' }) do
      expect(URI.parse(attachment.push_event_data.fetch(:data_url)).host).to eq(subscription.service_host)
      expect(URI.parse(attachment.download_url).host).to eq(subscription.service_host)
      expect(ActiveStorage::Current.url_options[:host]).to eq('neighbor.example.test')
    end
  end
end
