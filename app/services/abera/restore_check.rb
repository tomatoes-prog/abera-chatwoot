class Abera::RestoreCheck
  # Run only in the isolated administration process. A temporary database avoids
  # collisions with live channel tokens while retaining the real schema and constraints.
  def initialize(snapshot)
    @snapshot = snapshot.deep_stringify_keys
  end

  def run
    administrative = Abera::Current.administrative_operation
    Abera::Current.administrative_operation = true
    open_database
    importer = import_snapshot
    restored = Account.find(importer.mapping.fetch('accounts').fetch(@snapshot.fetch('source_account_id')))
    counts = verify_counts!
    yield restored, importer if block_given?
    { 'restoredAccountId' => restored.id, 'checkedAt' => Time.current.iso8601, 'tableCounts' => counts }
  ensure
    begin
      close_database
    ensure
      Abera::Current.administrative_operation = administrative
    end
  end

  private

  def open_database
    @configuration = ApplicationRecord.connection_db_config.configuration_hash
    options = @configuration.slice(:host, :port, :password, :sslmode, :sslrootcert)
    options[:dbname] = @configuration.fetch(:database)
    options[:user] = @configuration.fetch(:username)
    @control = PG.connect(options)
    @database = "abera_restore_check_#{SecureRandom.hex(12)}"
    @control.exec('SELECT pg_advisory_lock(721170030)')
    @control.exec("CREATE DATABASE #{PG::Connection.quote_ident(@database)}")
    @created = true
    ApplicationRecord.establish_connection(@configuration.merge(database: @database))
  end

  def import_snapshot
    ActiveRecord::Migration.suppress_messages { load Rails.root.join('db/schema.rb') }
    ActiveRecord::Migration.suppress_messages { ApplicationRecord.connection.migration_context.migrate }
    importer = Abera::AccountImport.new(@snapshot, blob_prefix: "verification/#{@database}")
    importer.restore!
    importer
  end

  def verify_counts!
    counts = @snapshot.fetch('tables').transform_values(&:size)
    counts.each do |table, expected|
      actual = ApplicationRecord.connection.select_value("SELECT COUNT(*) FROM #{ApplicationRecord.connection.quote_table_name(table)}").to_i
      raise "Restore row count mismatch: #{table}" unless actual == expected
    end
    counts
  end

  def close_database
    if @created
      ApplicationRecord.establish_connection(@configuration)
      @control.exec("DROP DATABASE #{PG::Connection.quote_ident(@database)} WITH (FORCE)")
    end
    @control&.exec('SELECT pg_advisory_unlock(721170030)')
  ensure
    @control&.close
  end
end
