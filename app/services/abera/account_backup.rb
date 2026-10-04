require 'aws-sdk-s3'
require 'base64'
require 'stringio'
require 'tempfile'
require 'zlib'

class Abera::AccountBackup
  def initialize(command, storage_client: Aws::S3::Client.new)
    @command = command.deep_stringify_keys
    @s3 = storage_client
    @bucket = ENV.fetch('ABERA_OPERATION_BUCKET')
    @files_bucket = ENV.fetch('S3_BUCKET_NAME')
    @key_arn = ENV.fetch('ABERA_DATA_KEY_ARN')
    @subscription = Abera::Subscription.find_by!(subscription_id: @command.fetch('subscriptionId'))
    raise 'Subscription owner mismatch' unless @subscription.customer_id == @command.fetch('customerId')
    if @command.key?('accountId') && @subscription.account_id != @command.fetch('accountId').to_i
      raise 'Account changed since the operation was prepared'
    end

    id = @command.fetch('backupId')
    raise 'Invalid backup identity' unless id.match?(/\A[a-z0-9-]{3,128}\z/)

    category = @command.fetch('backupClass')
    raise 'Invalid backup category' unless %w[weekly recovery].include?(category)

    @prefix = "#{category}/#{@subscription.subscription_id}/#{id}/"
  end

  def run
    previous = completed_backup
    return previous if previous

    snapshot = Abera::AccountSnapshot.new(@subscription.account).export.deep_stringify_keys
    artifacts = write_snapshot(snapshot)
    evidence = verify_artifacts(artifacts)
    manifest = build_manifest(snapshot, artifacts, evidence)
    stored = write_object('manifest.json', JSON.generate(manifest))
    backup_receipt(manifest, stored)
  end

  private

  def write_snapshot(snapshot)
    compressed = StringIO.new
    Zlib::GzipWriter.wrap(compressed) { |writer| writer.write(JSON.generate(snapshot)) }
    database = write_object('database.json.gz', compressed.string)
    files = snapshot.fetch('tables').fetch('active_storage_blobs', []).map { |blob| copy_blob(blob) }
    { 'database' => database, 'files' => write_object('files.json', JSON.generate(files)),
      'applicationSecrets' => write_object('application-state.json', JSON.generate(snapshot.fetch('managed_state'))) }
  end

  def verify_artifacts(artifacts)
    verified_database = read_artifact(artifacts.fetch('database'))
    snapshot = JSON.parse(Zlib::GzipReader.wrap(StringIO.new(verified_database), &:read))
    state = JSON.parse(read_artifact(artifacts.fetch('applicationSecrets')))
    raise 'Application state backup differs' unless state == snapshot.fetch('managed_state')

    verify_restore(snapshot, JSON.parse(read_artifact(artifacts.fetch('files'))))
  end

  def build_manifest(snapshot, artifacts, evidence)
    scope = @key_arn.split(':')
    {
      'version' => 1, 'subscriptionId' => @subscription.subscription_id, 'customerId' => @subscription.customer_id,
      'productId' => 'abera-chatwoot', 'productVersion' => @command.fetch('productVersion'),
      'environment' => @command.fetch('environment'), 'accountId' => scope.fetch(4), 'region' => scope.fetch(3),
      'dataGeneration' => @command.fetch('dataGeneration'), 'archiveCycleId' => @command['archiveCycleId'],
      'backupId' => @command.fetch('backupId'), 'compatibilityGeneration' => 'chatwoot-ce-pg16-v1',
      'databaseFormat' => 'account-graph-json-gzip-v1', 'databaseBytes' => JSON.generate(snapshot.fetch('tables')).bytesize,
      'artifacts' => artifacts,
      'restoreTested' => true, 'verified' => true, 'restoreEvidence' => evidence, 'createdAt' => Time.current.iso8601
    }
  end

  def backup_receipt(manifest, stored)
    manifest.merge('bucket' => @bucket, 'manifestKey' => stored.fetch('key'),
                   'manifestVersionId' => stored.fetch('versionId'), 'manifestSha256' => stored.fetch('sha256'))
  end

  def completed_backup
    stored = @s3.get_object(bucket: @bucket, key: "#{@prefix}manifest.json")
    content = stored.body.read
    manifest = JSON.parse(content)
    expected = @command.slice('subscriptionId', 'customerId', 'productVersion', 'environment', 'dataGeneration', 'backupId', 'archiveCycleId')
    scope = @key_arn.split(':')
    expected.merge!('version' => 1, 'productId' => 'abera-chatwoot', 'accountId' => scope.fetch(4), 'region' => scope.fetch(3))
    raise 'Backup identity differs from the operation' unless expected.all? { |name, value| manifest[name] == value }
    raise 'Backup has no successful restore evidence' unless manifest.fetch('verified') && manifest.fetch('restoreTested')

    require_version!(stored.version_id)

    backup_receipt(manifest, { 'key' => "#{@prefix}manifest.json", 'versionId' => stored.version_id,
                               'sha256' => Digest::SHA256.hexdigest(content) })
  rescue Aws::S3::Errors::NoSuchKey
    nil
  end

  def read_artifact(artifact)
    content = @s3.get_object(bucket: @bucket, key: artifact.fetch('key'), version_id: artifact.fetch('versionId')).body.read
    raise 'Backup artifact checksum mismatch' unless Digest::SHA256.hexdigest(content) == artifact.fetch('sha256')

    content
  end

  def write_object(name, content)
    key = @prefix + name
    result = @s3.put_object(bucket: @bucket, key: key, body: content, server_side_encryption: 'aws:kms', ssekms_key_id: @key_arn)
    require_version!(result.version_id)

    { 'key' => key, 'versionId' => result.version_id, 'sha256' => Digest::SHA256.hexdigest(content) }
  end

  def copy_blob(blob)
    unless Abera::BlobAccess.allowed?(ActiveStorage::Blob.find(blob.fetch('id')), @subscription)
      raise 'Attachment ownership does not match the backup subscription'
    end

    source = @s3.head_object(bucket: @files_bucket, key: blob.fetch('key'))
    require_version!(source.version_id)

    Tempfile.create(['abera-attachment', '.bin'], binmode: true) do |file|
      @s3.get_object(bucket: @files_bucket, key: blob.fetch('key'), version_id: source.version_id, response_target: file.path)
      check_blob!(file.path, blob)
      key = "#{@prefix}attachments/#{blob.fetch('id')}"
      stored = store_file(@bucket, key, file)
      attachment_artifact(blob, source, stored, key, file.path)
    end
  end

  def attachment_artifact(blob, source, stored, key, path)
    { 'blobId' => blob.fetch('id'), 'key' => key, 'versionId' => stored.version_id,
      'sha256' => Digest::SHA256.file(path).hexdigest, 'sourceKey' => blob.fetch('key'), 'sourceVersionId' => source.version_id,
      'byteSize' => blob.fetch('byte_size'), 'checksum' => blob.fetch('checksum') }
  end

  def store_file(bucket, key, file)
    file.rewind
    stored = @s3.put_object(bucket: bucket, key: key, body: file, server_side_encryption: 'aws:kms', ssekms_key_id: @key_arn)
    require_version!(stored.version_id)
    stored
  end

  def require_version!(version)
    raise 'Storage must retain exact object versions' if version.blank? || version == 'null'
  end

  def check_blob!(path, blob)
    checksum = Base64.strict_encode64(Digest::MD5.file(path).digest)
    raise ActiveStorage::IntegrityError unless File.size(path) == blob.fetch('byte_size') && checksum == blob.fetch('checksum')
  end

  def verify_restore(snapshot, files)
    uploaded = []
    Abera::RestoreCheck.new(snapshot).run do |_account, importer|
      files.each do |artifact|
        restored = ActiveStorage::Blob.find(importer.mapping.fetch('active_storage_blobs').fetch(artifact.fetch('blobId')))
        restore_verification_file(artifact, restored, uploaded)
      end
    end.merge('restoredFiles' => files.size, 'restoredFileBytes' => files.sum { |file| file.fetch('byteSize') })
  ensure
    uploaded&.each { |object| @s3.delete_object(bucket: @files_bucket, **object) }
  end

  def restore_verification_file(artifact, restored, uploaded)
    Tempfile.create(['abera-restore', '.bin'], binmode: true) do |file|
      @s3.get_object(bucket: @bucket, key: artifact.fetch('key'), version_id: artifact.fetch('versionId'), response_target: file.path)
      raise 'Restored attachment checksum mismatch' unless Digest::SHA256.file(file.path).hexdigest == artifact.fetch('sha256')

      stored = store_file(@files_bucket, restored.key, file)
      uploaded << { key: restored.key, version_id: stored.version_id }
      restored.open { |downloaded| check_blob!(downloaded.path, restored.attributes) }
    end
  end
end
