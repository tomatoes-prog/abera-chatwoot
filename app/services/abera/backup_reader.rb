require 'aws-sdk-s3'
require 'stringio'
require 'zlib'

class Abera::BackupReader
  attr_reader :manifest, :files

  def initialize(command, storage_client: Aws::S3::Client.new)
    @command = command
    @s3 = storage_client
    @receipt = command.fetch('backup')
    @bucket = ENV.fetch('ABERA_OPERATION_BUCKET')
  end

  def snapshot
    raise 'Backup bucket mismatch' unless @receipt.fetch('bucket') == @bucket

    raw = read('key' => @receipt.fetch('manifestKey'), 'versionId' => @receipt.fetch('manifestVersionId'),
               'sha256' => @receipt.fetch('manifestSha256'))
    @manifest = JSON.parse(raw)
    validate_identity!
    artifacts = @manifest.fetch('artifacts')
    data = JSON.parse(Zlib::GzipReader.wrap(StringIO.new(read(artifacts.fetch('database'))), &:read))
    state = JSON.parse(read(artifacts.fetch('applicationSecrets')))
    raise 'Backup application state mismatch' unless state == data.fetch('managed_state')

    @files = JSON.parse(read(artifacts.fetch('files')))
    data
  end

  def read(artifact)
    prefix = @receipt.fetch('manifestKey').delete_suffix('manifest.json')
    raise 'Backup artifact outside subscription prefix' unless artifact.fetch('key').start_with?(prefix)
    raise 'Backup must specify an exact object version' if artifact.fetch('versionId').blank? || artifact.fetch('versionId') == 'null'

    body = @s3.get_object(bucket: @bucket, key: artifact.fetch('key'), version_id: artifact.fetch('versionId')).body.read
    raise 'Backup checksum mismatch' unless Digest::SHA256.hexdigest(body) == artifact.fetch('sha256')

    body
  end

  private

  def validate_identity!
    scope = ENV.fetch('ABERA_DATA_KEY_ARN').split(':')
    expected = @command.slice('subscriptionId', 'customerId', 'environment')
    expected.merge!('accountId' => scope.fetch(4), 'region' => scope.fetch(3), 'productId' => 'abera-chatwoot',
                    'compatibilityGeneration' => 'chatwoot-ce-pg16-v1', 'verified' => true, 'restoreTested' => true)
    raise 'Backup identity mismatch' unless expected.all? { |key, value| @manifest[key] == value }
    raise 'Backup receipt mismatch' unless @manifest.all? { |key, value| @receipt[key] == value }

    validate_prefix!
  end

  def validate_prefix!
    category = @command.fetch('backupClass')
    raise 'Invalid backup category' unless %w[weekly recovery].include?(category)

    id = @manifest.fetch('backupId')
    raise 'Invalid backup identity' unless id.match?(/\A[a-z0-9-]{3,128}\z/)
    raise 'Backup prefix mismatch' unless @receipt.fetch('manifestKey') == "#{category}/#{@command.fetch('subscriptionId')}/#{id}/manifest.json"
  end
end
