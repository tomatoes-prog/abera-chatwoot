require 'rails_helper'

RSpec.describe Abera::AccountBackup do
  let(:account) { create(:account) }
  let!(:subscription) do
    Abera::Subscription.create!(account: account, subscription_id: 'backup-one', customer_id: 'owner-one',
                               service_host: 'backup.example.test', tier: 'lite', state: 'active')
  end
  let(:client) { Aws::S3::Client.new(stub_responses: true, region: 'us-east-2') }
  let(:command) do
    { subscriptionId: 'backup-one', customerId: 'owner-one', productVersion: '1.1.0', environment: 'dev',
      dataGeneration: 1, backupId: 'backup-operation', backupClass: 'weekly' }
  end
  let(:manifest) do
    command.except(:backupClass).stringify_keys.merge('version' => 1, 'productId' => 'abera-chatwoot',
                                                     'accountId' => '123456789012', 'region' => 'us-east-2',
                                                     'verified' => true, 'restoreTested' => true)
  end

  around do |example|
    with_modified_env(ABERA_OPERATION_BUCKET: 'private-backups', S3_BUCKET_NAME: 'private-attachments',
                      ABERA_DATA_KEY_ARN: 'arn:aws:kms:us-east-2:123456789012:key/test-key') { example.run }
  end

  it 'reuses the exact verified manifest version on retry without rewriting data' do
    body = JSON.generate(manifest)
    client.stub_responses(:get_object, body: body, version_id: 'immutable-version')
    result = described_class.new(command, storage_client: client).run
    expect(result.fetch('manifestVersionId')).to eq('immutable-version')
    expect(result.fetch('manifestSha256')).to eq(Digest::SHA256.hexdigest(body))
    expect(client.api_requests.map { |request| request[:operation_name] }).to eq([:get_object])
  end

  it 'rejects a manifest that belongs to another subscription' do
    client.stub_responses(:get_object, body: JSON.generate(manifest.merge('subscriptionId' => 'neighbor')), version_id: 'version')
    expect { described_class.new(command, storage_client: client).run }.to raise_error(/Backup identity differs/)
  end

  it 'rejects a manifest without successful restore evidence' do
    client.stub_responses(:get_object, body: JSON.generate(manifest.merge('restoreTested' => false)), version_id: 'version')
    expect { described_class.new(command, storage_client: client).run }.to raise_error(/no successful restore evidence/)
  end
end
