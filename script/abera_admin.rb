# Commands and results are private S3 objects; credentials never enter task logs.
require 'aws-sdk-s3'

s3 = Aws::S3::Client.new
bucket = ENV.fetch('ABERA_OPERATION_BUCKET')
key = ENV.fetch('ABERA_COMMAND_KEY')
raise 'Invalid operation command key' unless key.start_with?('operations/')

command = JSON.parse(s3.get_object(bucket: bucket, key: key).body.read)
if command.fetch('action') == 'MIGRATE'
  require 'rake'
  connection = ApplicationRecord.connection
  connection.execute('SELECT pg_advisory_lock(721170029)')
  begin
    Rails.application.load_tasks
    Rake::Task['db:prepare'].invoke
    raise 'Pending migrations remain' if ActiveRecord::Base.connection.migration_context.needs_migration?

    Abera::InstallationSetup.run

    result = { 'subscriptionId' => command.fetch('subscriptionId'), 'state' => 'migrated',
               'sourceSha' => Rails.root.join('.git_sha').read.strip }
  ensure
    connection.execute('SELECT pg_advisory_unlock(721170029)')
  end
elsif command.fetch('action') == 'BACKUP'
  result = Abera::AccountBackup.new(command).run
else
  result = Abera::Administration.new(command).run
end
Abera::ObjectCleanup.new.run(result.fetch('attachmentKeys', []))
s3.put_object(bucket: bucket, key: ENV.fetch('ABERA_RESULT_KEY'), body: JSON.generate(result),
              server_side_encryption: 'aws:kms', ssekms_key_id: ENV.fetch('ABERA_DATA_KEY_ARN'), content_type: 'application/json')
