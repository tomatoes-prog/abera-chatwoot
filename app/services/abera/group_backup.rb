require 'aws-sdk-s3'
require 'open3'
require 'tempfile'

# Lite needs a database-wide copy in addition to each subscription's portable backup.
class Abera::GroupBackup
  LOCK_ID = 721_170_030
  KEY_NAMES = %w[SECRET_KEY_BASE ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY
                 ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT].freeze

  def initialize(command, storage_client: Aws::S3::Client.new)
    @command = command.deep_stringify_keys
    @s3 = storage_client
    @group_id = ENV.fetch('ABERA_GROUP_ID')
    raise 'Group backups only support Lite' unless ENV.fetch('ABERA_TIER') == 'lite'
    raise 'Invalid group identity' unless @group_id.match?(/\A[a-f0-9]{16}\z/)

    @bucket = ENV.fetch('ABERA_OPERATION_BUCKET')
    @files_bucket = ENV.fetch('S3_BUCKET_NAME')
    @key_arn = ENV.fetch('ABERA_DATA_KEY_ARN')
    @prefix = "weekly/groups/#{@group_id}/#{Time.current.strftime('%G-%V')}/"
  end

  def run
    connection = ApplicationRecord.connection
    connection.execute("SELECT pg_advisory_lock(#{LOCK_ID})")
    begin
      previous = completed_backup
      return previous if previous

      Tempfile.create(['abera-group', '.dump'], binmode: true) { |dump| build_backup(dump) }
    ensure
      connection.execute("SELECT pg_advisory_unlock(#{LOCK_ID})")
    end
  end

  private

  def capture_dump(dump)
    ApplicationRecord.transaction(isolation: :repeatable_read) do
      connection = ApplicationRecord.connection
      snapshot_id = connection.select_value('SELECT pg_export_snapshot()')
      context = { 'tables' => table_counts(connection), 'files' => ActiveStorage::Blob.order(:id).map { |blob| copy_blob(blob) } }
      run_pg!('pg_dump', '--format=custom', '--no-owner', '--no-acl', "--snapshot=#{snapshot_id}", "--file=#{dump.path}")
      context
    end
  end

  def build_backup(dump)
    context = capture_dump(dump)
    database = store_file('postgres.dump', dump)
    @s3.get_object(bucket: @bucket, key: database.fetch('key'), version_id: database.fetch('versionId'), response_target: dump.path)
    raise 'Stored group dump checksum differs' unless Digest::SHA256.file(dump.path).hexdigest == database.fetch('sha256')

    evidence = verify_database(dump.path, context.fetch('tables')).merge('verifiedFiles' => context.fetch('files').size)
    publish_manifest(database, context.fetch('files'), evidence)
  end

  def publish_manifest(database, files, evidence)
    artifacts = { 'database' => database, 'files' => store_json('files.json', files),
                  'encryptionKeys' => store_json('encryption-keys.json', KEY_NAMES.index_with { |name| ENV.fetch(name) }) }
    manifest = { 'version' => 1, 'productId' => 'abera-chatwoot', 'groupId' => @group_id,
                 'environment' => @command.fetch('environment'), 'productVersion' => @command.fetch('productVersion'),
                 'sourceSha' => Rails.root.join('.git_sha').read.strip,
                 'databaseFormat' => 'postgres-custom-pg16-v1', 'createdAt' => Time.current.iso8601,
                 'artifacts' => artifacts, 'verified' => true, 'restoreEvidence' => evidence }
    stored = store_json('manifest.json', manifest)
    manifest.merge('bucket' => @bucket, 'manifestKey' => stored.fetch('key'),
                   'manifestVersionId' => stored.fetch('versionId'), 'manifestSha256' => stored.fetch('sha256'))
  end

  def pg_environment(database = nil)
    config = ApplicationRecord.connection_db_config.configuration_hash
    { 'PGHOST' => config.fetch(:host).to_s, 'PGPORT' => config.fetch(:port, 5432).to_s,
      'PGUSER' => config.fetch(:username), 'PGPASSWORD' => config.fetch(:password),
      'PGDATABASE' => database || config.fetch(:database) }
  end

  def run_pg!(*, database: nil)
    _out, _err, result = Open3.capture3(pg_environment(database), *)
    raise 'Group PostgreSQL backup or verification failed' unless result.success?
  end

  def table_counts(connection)
    connection.tables.sort.index_with { |table| connection.select_value("SELECT COUNT(*) FROM #{connection.quote_table_name(table)}").to_i }
  end

  def verify_database(path, expected)
    database = "abera_verify_#{SecureRandom.hex(8)}"
    connection = ApplicationRecord.connection
    connection.execute("CREATE DATABASE #{connection.quote_table_name(database)}")
    begin
      run_pg!('pg_restore', '--exit-on-error', '--single-transaction', '--no-owner', '--no-acl', "--dbname=#{database}", path)
      config = ApplicationRecord.connection_db_config.configuration_hash
      restored = PG.connect(host: config.fetch(:host), port: config.fetch(:port, 5432), user: config.fetch(:username),
                            password: config.fetch(:password), dbname: database)
      begin
        verify_counts(restored, expected)
      ensure
        restored.close
      end
      { 'method' => 'pg_restore-isolated-database', 'tables' => expected }
    ensure
      connection.execute("DROP DATABASE #{connection.quote_table_name(database)} WITH (FORCE)")
    end
  end

  def verify_counts(restored, expected)
    expected.each do |table, count|
      actual = restored.exec("SELECT COUNT(*) FROM #{restored.escape_identifier(table)}").getvalue(0, 0).to_i
      raise 'Group restore verification differs' unless actual == count
    end
  end

  def copy_blob(blob)
    source = @s3.head_object(bucket: @files_bucket, key: blob.key)
    raise 'Attachment has no durable object version' if source.version_id.blank? || source.version_id == 'null'

    Tempfile.create(['abera-group-file', '.bin'], binmode: true) do |file|
      @s3.get_object(bucket: @files_bucket, key: blob.key, version_id: source.version_id, response_target: file.path)
      verify_blob(file, blob)

      store_file("attachments/#{blob.id}", file).merge('sourceKey' => blob.key, 'sourceVersionId' => source.version_id)
    end
  end

  def verify_blob(file, blob)
    return if File.size(file.path) == blob.byte_size && Base64.strict_encode64(Digest::MD5.file(file.path).digest) == blob.checksum

    raise ActiveStorage::IntegrityError
  end

  def store_json(name, value)
    Tempfile.create(['abera-group-json', '.json'], binmode: true) do |file|
      file.write(JSON.generate(value))
      file.flush
      store_file(name, file)
    end
  end

  def store_file(name, file)
    file.rewind
    stored = @s3.put_object(bucket: @bucket, key: @prefix + name, body: file,
                            server_side_encryption: 'aws:kms', ssekms_key_id: @key_arn)
    raise 'Group backup storage must retain versions' if stored.version_id.blank? || stored.version_id == 'null'

    reference = { 'key' => @prefix + name, 'versionId' => stored.version_id, 'sha256' => Digest::SHA256.file(file.path).hexdigest }
    verify_stored(reference)
    reference
  end

  def verify_stored(reference)
    Tempfile.create(['abera-group-check', '.bin'], binmode: true) do |copy|
      @s3.get_object(bucket: @bucket, key: reference.fetch('key'), version_id: reference.fetch('versionId'), response_target: copy.path)
      raise 'Stored group artifact checksum differs' unless Digest::SHA256.file(copy.path).hexdigest == reference.fetch('sha256')
    end
  end

  def completed_backup
    stored = @s3.get_object(bucket: @bucket, key: "#{@prefix}manifest.json")
    body = stored.body.read
    manifest = JSON.parse(body)
    expected = @command.slice('environment', 'productVersion').merge('version' => 1, 'groupId' => @group_id, 'productId' => 'abera-chatwoot')
    raise 'Group backup identity differs' unless expected.all? { |key, value| manifest[key] == value } && manifest['verified'] == true

    raise 'Group manifest has no durable version' if stored.version_id.blank? || stored.version_id == 'null'

    manifest.merge('bucket' => @bucket, 'manifestKey' => "#{@prefix}manifest.json",
                   'manifestVersionId' => stored.version_id, 'manifestSha256' => Digest::SHA256.hexdigest(body))
  rescue Aws::S3::Errors::NoSuchKey
    nil
  end
end
