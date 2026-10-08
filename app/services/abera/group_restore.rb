require 'aws-sdk-s3'
require 'open3'
require 'tempfile'

# Whole-group disaster recovery is separate from the subscription RESTORE operation.
class Abera::GroupRestore
  def initialize(command, storage_client: Aws::S3::Client.new)
    @command = command.deep_stringify_keys
    @s3 = storage_client
    @bucket = ENV.fetch('ABERA_OPERATION_BUCKET')
    @group_id = ENV.fetch('ABERA_GROUP_ID')
    return if ENV.fetch('ABERA_TIER') == 'lite' && @command.fetch('confirmGroupId') == @group_id && ENV['ABERA_GROUP_RECOVERY_MODE'] == 'offline'

    raise 'Whole-group restore requires explicit confirmation of the Lite group'
  end

  def run
    connection = ApplicationRecord.connection
    connection.execute("SELECT pg_advisory_lock(#{Abera::GroupBackup::LOCK_ID})")
    begin
      raise 'Whole-group restore requires an empty database' unless connection.tables.empty?

      restore_snapshot(read_manifest)
    ensure
      connection.execute("SELECT pg_advisory_unlock(#{Abera::GroupBackup::LOCK_ID})")
    end
  end

  private

  def restore_snapshot(manifest)
    artifacts = manifest.fetch('artifacts')
    keys = read_json(artifacts.fetch('encryptionKeys'))
    unless Abera::GroupBackup::KEY_NAMES.all? { |name| keys.fetch(name) == ENV.fetch(name) }
      raise 'Restore requires the original runtime encryption keys'
    end

    files = read_json(artifacts.fetch('files'))
    restore_files(files)
    restore_database(artifacts.fetch('database'))
    connection = ApplicationRecord.connection
    manifest.fetch('restoreEvidence').fetch('tables').each do |table, count|
      actual = connection.select_value("SELECT COUNT(*) FROM #{connection.quote_table_name(table)}").to_i
      raise 'Whole-group restore verification differs; keep ingress closed' unless actual == count
    end
    # Billing and the control plane remain authoritative after a point-in-time
    # restore. Keep every restored tenant fenced until its entitlement is reconciled.
    connection.execute("UPDATE abera_subscriptions SET state = 'quiescing'")
    { 'subscriptionId' => @command.fetch('subscriptionId'), 'groupId' => @group_id,
      'state' => 'group-restored-offline', 'restoredFiles' => files.size, 'verified' => true, 'entitlementReconciliationRequired' => true }
  end

  def restore_files(files)
    files.each do |artifact|
      with_artifact(artifact) do |file|
        restore_file(file, artifact)
      end
    end
  end

  def restore_file(file, artifact)
    bucket = ENV.fetch('S3_BUCKET_NAME')
    key = artifact.fetch('sourceKey')
    stored = @s3.put_object(bucket: bucket, key: key, body: file,
                            server_side_encryption: 'aws:kms', ssekms_key_id: ENV.fetch('ABERA_DATA_KEY_ARN'))
    raise 'Restored attachment has no durable version' if stored.version_id.blank? || stored.version_id == 'null'

    @s3.get_object(bucket: bucket, key: key, version_id: stored.version_id, response_target: file.path)
    raise 'Restored attachment checksum differs' unless Digest::SHA256.file(file.path).hexdigest == artifact.fetch('sha256')
  end

  def restore_database(artifact)
    with_artifact(artifact) do |file|
      config = ApplicationRecord.connection_db_config.configuration_hash
      env = { 'PGHOST' => config.fetch(:host).to_s, 'PGPORT' => config.fetch(:port, 5432).to_s,
              'PGUSER' => config.fetch(:username), 'PGPASSWORD' => config.fetch(:password), 'PGDATABASE' => config.fetch(:database) }
      _out, _err, status = Open3.capture3(env, 'pg_restore', '--exit-on-error', '--single-transaction',
                                          '--no-owner', '--no-acl', "--dbname=#{config.fetch(:database)}", file.path)
      raise 'Whole-group PostgreSQL restore failed; keep ingress closed' unless status.success?
    end
  end

  def read_manifest
    reference = @command.fetch('groupBackup')
    key = reference.fetch('manifestKey')
    raise 'Group manifest belongs to another group' unless key.start_with?("weekly/groups/#{@group_id}/")

    object = @s3.get_object(bucket: @bucket, key: key, version_id: reference.fetch('manifestVersionId'))
    body = object.body.read
    raise 'Group manifest checksum differs' unless Digest::SHA256.hexdigest(body) == reference.fetch('manifestSha256')

    manifest = JSON.parse(body)
    expected = @command.slice('environment', 'productVersion').merge('version' => 1, 'productId' => 'abera-chatwoot', 'groupId' => @group_id,
                                                                     'sourceSha' => Rails.root.join('.git_sha').read.strip,
                                                                     'databaseFormat' => 'postgres-custom-pg16-v1')
    unless expected.all? { |name, value| manifest[name] == value } && manifest['verified'] == true
      raise 'Group manifest identity or verification differs'
    end

    manifest
  end

  def read_json(artifact)
    with_artifact(artifact) { |file| JSON.parse(file.read) }
  end

  def with_artifact(artifact)
    unless artifact.fetch('key').start_with?("weekly/groups/#{@group_id}/") && artifact.fetch('versionId') != 'null'
      raise 'Group artifact belongs to another group or has no version'
    end

    Tempfile.create(['abera-group-restore', '.bin'], binmode: true) do |file|
      @s3.get_object(bucket: @bucket, key: artifact.fetch('key'), version_id: artifact.fetch('versionId'), response_target: file.path)
      raise 'Group artifact checksum differs' unless Digest::SHA256.file(file.path).hexdigest == artifact.fetch('sha256')

      file.rewind
      yield file
    end
  end
end
