require 'rails_helper'

RSpec.describe Abera::GroupBackup do
  self.use_transactional_tests = false

  let(:objects) { {} }
  let(:versions) { {} }
  let(:client) { instance_double(Aws::S3::Client) }
  let(:command) { { environment: 'dev', productVersion: '1.1.1', subscriptionId: 'one', confirmGroupId: '0123456789abcdef' } }

  around do |example|
    with_modified_env(ABERA_GROUP_ID: '0123456789abcdef', ABERA_TIER: 'lite', ABERA_GROUP_RECOVERY_MODE: 'offline',
                      ABERA_OPERATION_BUCKET: 'private-backups', S3_BUCKET_NAME: 'private-files',
                      ABERA_DATA_KEY_ARN: 'arn:aws:kms:us-east-2:123456789012:key/test',
                      SECRET_KEY_BASE: 'test-only-group-backup-secret-key-base') { example.run }
  end

  before do
    allow(Rails.root).to receive(:join).and_call_original
    allow(Rails.root).to receive(:join).with('.git_sha').and_return(instance_double(Pathname, read: 'a' * 40))
    allow(client).to receive(:put_object) do |**args|
      version = SecureRandom.uuid
      body = args.fetch(:body).respond_to?(:read) ? args.fetch(:body).read : args.fetch(:body)
      objects[[args.fetch(:bucket), args.fetch(:key), version]] = body
      versions[[args.fetch(:bucket), args.fetch(:key)]] = version
      Aws::S3::Types::PutObjectOutput.new(version_id: version)
    end
    allow(client).to receive(:get_object) do |**args|
      version = args[:version_id] || versions[[args.fetch(:bucket), args.fetch(:key)]]
      body = objects[[args.fetch(:bucket), args.fetch(:key), version]]
      raise Aws::S3::Errors::NoSuchKey.new(nil, 'Missing') unless body

      File.binwrite(args[:response_target], body) if args[:response_target]
      Aws::S3::Types::GetObjectOutput.new(body: StringIO.new(body), version_id: version)
    end
    allow(client).to receive(:head_object) do |**args|
      Aws::S3::Types::HeadObjectOutput.new(version_id: versions.fetch([args.fetch(:bucket), args.fetch(:key)]))
    end
  end

  it 'restores the full PostgreSQL database into an isolated database and reuses its receipt' do
    first = create(:account, name: 'Backup source')
    neighbor = create(:account, name: 'Preserved neighbor')
    bytes = 'durable attachment bytes'
    blob = ActiveStorage::Blob.create!(filename: 'audit.txt', content_type: 'text/plain', byte_size: bytes.bytesize,
                                       checksum: Base64.strict_encode64(Digest::MD5.digest(bytes)), service_name: 'test')
    client.put_object(bucket: 'private-files', key: blob.key, body: bytes)
    [first, neighbor].each do |account|
      Abera::Subscription.create!(account: account, subscription_id: "backup-#{account.id}", customer_id: "customer-#{account.id}",
                                  service_host: "backup-#{account.id}.example.test", tier: 'lite', state: 'active',
                                  agent_limit: 2, conversation_limit: 500, storage_limit_bytes: 2.gigabytes)
    end
    config = ApplicationRecord.connection_db_config.configuration_hash
    restored_name = "abera_restore_#{SecureRandom.hex(8)}"
    original = ApplicationRecord.connection
    original.execute("CREATE DATABASE #{original.quote_table_name(restored_name)}")
    begin
      receipt = described_class.new(command, storage_client: client).run
      expect(receipt.fetch('restoreEvidence').fetch('method')).to eq('pg_restore-isolated-database')
      retry_receipt = described_class.new(command, storage_client: client).run
      expect(retry_receipt.fetch('manifestVersionId')).to eq(receipt.fetch('manifestVersionId'))
      ApplicationRecord.establish_connection(config.merge(database: restored_name))
      result = Abera::GroupRestore.new(command.merge(groupBackup: receipt), storage_client: client).run
      expect(result).to include('verified' => true, 'restoredFiles' => 1)
      restored_version = versions.fetch(['private-files', blob.key])
      expect(objects.fetch(['private-files', blob.key, restored_version])).to eq(bytes)
      names = ApplicationRecord.connection.select_values("SELECT name FROM accounts WHERE id IN (#{first.id}, #{neighbor.id}) ORDER BY id")
      expect(names).to eq(['Backup source', 'Preserved neighbor'])
      states = ApplicationRecord.connection.select_values('SELECT state FROM abera_subscriptions')
      expect(states).to all(eq('quiescing'))
      expect do
        Abera::GroupRestore.new(command.merge(groupBackup: receipt), storage_client: client).run
      end.to raise_error(/empty database/)
    ensure
      ApplicationRecord.establish_connection(config)
      ApplicationRecord.connection.execute("DROP DATABASE #{ApplicationRecord.connection.quote_table_name(restored_name)} WITH (FORCE)")
      first.destroy!
      neighbor.destroy!
      blob.destroy!
    end
  end

  it 'rejects disaster recovery without the explicit offline mode' do
    with_modified_env(ABERA_GROUP_RECOVERY_MODE: nil) do
      expect { Abera::GroupRestore.new(command, storage_client: client) }.to raise_error(/explicit confirmation/)
    end
  end

  it 'rejects a group manifest for another group before starting a database copy' do
    allow(client).to receive(:get_object).and_return(Aws::S3::Types::GetObjectOutput.new(
                                                       body: StringIO.new(JSON.generate({ groupId: 'neighbor' })), version_id: 'version'
                                                     ))
    expect { described_class.new(command, storage_client: client).run }.to raise_error(/identity differs/)
    expect(client).not_to have_received(:put_object)
  end
end
