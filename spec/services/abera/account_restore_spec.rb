require 'rails_helper'
require 'zlib'
require 'stringio'

RSpec.describe Abera::AccountRestore do
  let(:account) { create(:account) }
  let!(:conversation) { create(:conversation, account: account) }
  let!(:user) { create(:user, account: account, role: :administrator) }
  let(:neighbor) { create(:account) }
  let!(:neighbor_conversation) { create(:conversation, account: neighbor) }
  let!(:subscription) do
    Abera::Subscription.create!(account: account, subscription_id: 'restore-one', customer_id: 'owner-one',
                                service_host: 'restore.example.test', tier: 'lite', state: 'quiescing')
  end
  let(:snapshot) { Abera::AccountSnapshot.new(account).export.deep_stringify_keys }
  let(:prefix) { 'weekly/restore-one/backup-one/' }
  let(:database) do
    compressed = StringIO.new
    Zlib::GzipWriter.wrap(compressed) { |writer| writer.write(JSON.generate(snapshot)) }
    compressed.string
  end
  let(:objects) do
    { 'database' => database, 'applicationSecrets' => JSON.generate(snapshot.fetch('managed_state')), 'files' => '[]' }
  end
  let(:manifest) do
    { 'subscriptionId' => 'restore-one', 'customerId' => 'owner-one', 'environment' => 'dev', 'productId' => 'abera-chatwoot',
      'accountId' => '123456789012', 'region' => 'us-east-2', 'compatibilityGeneration' => 'chatwoot-ce-pg16-v1',
      'verified' => true, 'restoreTested' => true, 'backupId' => 'backup-one',
      'artifacts' => objects.transform_values.with_index do |body, index|
        { 'key' => "#{prefix}#{index}", 'versionId' => "version-#{index}", 'sha256' => Digest::SHA256.hexdigest(body) }
      end }
  end
  let(:receipt) do
    manifest.merge('bucket' => 'private-backups', 'manifestKey' => "#{prefix}manifest.json", 'manifestVersionId' => 'manifest-version',
                   'manifestSha256' => Digest::SHA256.hexdigest(JSON.generate(manifest)))
  end
  let(:command) do
    { 'operationId' => 'restore-operation', 'subscriptionId' => 'restore-one', 'customerId' => 'owner-one', 'action' => 'RESTORE',
      'environment' => 'dev', 'serviceHost' => 'restore.example.test', 'tier' => 'professional', 'backupClass' => 'weekly', 'backup' => receipt }
  end
  let(:storage) { Aws::S3::Client.new(stub_responses: true) }

  around do |example|
    with_modified_env(ABERA_MANAGED: 'true', ABERA_OPERATION_BUCKET: 'private-backups', S3_BUCKET_NAME: 'private-files',
                      ABERA_DATA_KEY_ARN: 'arn:aws:kms:us-east-2:123456789012:key/test') { example.run }
  end

  before do
    create(:message, account: account, conversation: conversation, inbox: conversation.inbox, content: 'Restore this message')
    storage.stub_responses(:get_object, [{ body: JSON.generate(manifest) }, { body: database },
                                         { body: objects.fetch('applicationSecrets') }, { body: '[]' }])
    allow(Aws::S3::Client).to receive(:new).and_return(storage)
  end

  it 'restores just the selected account, preserving credentials, display IDs and its host', :aggregate_failures do
    original_id = account.id
    display_id = conversation.display_id
    password = user.encrypted_password
    result = Abera::Administration.new(command).run
    restored = Abera::Subscription.find_by!(subscription_id: 'restore-one')
    expect(Account.exists?(original_id)).to be(false)
    expect(restored.account_id).not_to eq(original_id)
    expect(restored.tier).to eq('professional')
    expect(restored.state).to eq('quiescing')
    expect(restored.service_host).to eq('restore.example.test')
    expect(restored.account.conversations.find_by!(display_id: display_id).messages.first.content).to eq('Restore this message')
    expect(restored.account.users.first.encrypted_password).to eq(password)
    expect(neighbor.reload.conversations).to include(neighbor_conversation)
    expect(Abera::Administration.new(command).run).to eq(result)
    expect(storage.api_requests.count { |request| request[:operation_name] == :get_object }).to eq(4)
  end

  it 'rolls back account removal and import when restoring the graph fails', :aggregate_failures do
    allow(Abera::AccountImport).to receive(:new).and_wrap_original do |constructor, *arguments|
      constructor.call(*arguments).tap do |importer|
        allow(importer).to receive(:restore!).and_wrap_original do |restore|
          restore.call
          raise 'Import verification failed'
        end
      end
    end
    expect { Abera::Administration.new(command).run }.to raise_error(RuntimeError, 'Import verification failed')
    expect(account.reload.conversations).to include(conversation)
    expect(subscription.reload.account_id).to eq(account.id)
    expect(Abera::OperationReceipt.exists?(operation_id: 'restore-operation')).to be(false)
    expect(neighbor.reload.conversations).to include(neighbor_conversation)
  end

  it 'rejects corruption before removing source data', :aggregate_failures do
    storage.stub_responses(:get_object, [{ body: JSON.generate(manifest) }, { body: 'corrupted-database' }])
    expect { Abera::Administration.new(command).run }.to raise_error(RuntimeError, 'Backup checksum mismatch')
    expect(account.reload.conversations).to include(conversation)
    expect(subscription.reload.account_id).to eq(account.id)
  end
end
