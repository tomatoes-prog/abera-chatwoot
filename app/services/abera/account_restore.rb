require 'base64'

class Abera::AccountRestore
  def initialize(command, existing: nil, storage_client: Aws::S3::Client.new)
    @command = command
    @existing = existing
    @s3 = storage_client
    @uploaded = []
  end

  def run
    reader = Abera::BackupReader.new(@command, storage_client: @s3)
    snapshot = reader.snapshot
    validate_snapshot!(snapshot, reader.files)
    cleanup = @existing ? Abera::AccountRemoval.new(@existing).run.fetch('attachmentKeys') : []
    importer, account = import_account(snapshot)
    reader.files.each { |artifact| restore_file(reader, artifact, importer) }
    { 'subscriptionId' => @command.fetch('subscriptionId'), 'customerId' => @command.fetch('customerId'),
      'accountId' => account.id, 'state' => 'quiescing', 'attachmentKeys' => cleanup }
  end

  def cleanup_partial
    @uploaded.each { |object| @s3.delete_object(bucket: ENV.fetch('S3_BUCKET_NAME'), **object) }
  end

  private

  def validate_snapshot!(snapshot, files)
    identity = snapshot.fetch('managed_state').fetch('subscription').slice('subscription_id', 'customer_id')
    expected = { 'subscription_id' => @command.fetch('subscriptionId'), 'customer_id' => @command.fetch('customerId') }
    raise 'Backup managed account identity mismatch' unless identity == expected

    blobs = snapshot.fetch('tables').fetch('active_storage_blobs', []).pluck('id').sort
    raise 'Incomplete backup attachments' unless files.pluck('blobId').sort == blobs
  end

  def import_account(snapshot)
    attributes = snapshot.fetch('managed_state').fetch('subscription')
    attributes.merge!('service_host' => @command.fetch('serviceHost'), 'tier' => @command.fetch('tier'), 'state' => 'quiescing')
    importer = Abera::AccountImport.new(snapshot,
                                        blob_prefix: "subscriptions/#{@command.fetch('subscriptionId')}/restore-#{@command.fetch('operationId')}")
    account = importer.restore!
    account.update!(status: :suspended)
    [importer, account]
  end

  def restore_file(reader, artifact, importer)
    blob = ActiveStorage::Blob.find(importer.mapping.fetch('active_storage_blobs').fetch(artifact.fetch('blobId')))
    body = reader.read(artifact)
    checksum = Base64.strict_encode64(Digest::MD5.digest(body))
    raise ActiveStorage::IntegrityError unless body.bytesize == blob.byte_size && checksum == blob.checksum

    upload_file(blob, body)
    blob.open { |file| raise ActiveStorage::IntegrityError unless Digest::SHA256.file(file.path).hexdigest == artifact.fetch('sha256') }
  end

  def upload_file(blob, body)
    stored = @s3.put_object(bucket: ENV.fetch('S3_BUCKET_NAME'), key: blob.key, body: body,
                            server_side_encryption: 'aws:kms', ssekms_key_id: ENV.fetch('ABERA_DATA_KEY_ARN'))
    raise 'Restored attachment must retain an exact object version' if stored.version_id.blank? || stored.version_id == 'null'

    @uploaded << { key: blob.key, version_id: stored.version_id }
  end
end
