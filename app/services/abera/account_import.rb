class Abera::AccountImport
  attr_reader :mapping

  def initialize(snapshot, blob_prefix: "subscriptions/import-#{SecureRandom.hex(16)}")
    @snapshot = snapshot.deep_stringify_keys
    raise 'Unsupported account backup schema' unless @snapshot.fetch('schema_version') == 1

    Rails.application.eager_load!
    @models = ActiveRecord::Base.descendants.reject(&:abstract_class?).select(&:table_exists?).map(&:base_class).uniq.index_by(&:table_name)
    @mapping = {}
    @reused = Set.new
    @blob_prefix = blob_prefix
  end

  def restore!
    ApplicationRecord.transaction do
      Abera::ImportCompatibility.assert_eligible!(@snapshot)

      allocate_ids
      pending = @snapshot.fetch('tables').keys
      until pending.empty?
        table = pending.find { |candidate| dependencies(candidate).none? { |parent| pending.include?(parent) && parent != candidate } }
        raise "Unresolved backup dependencies: #{pending.join(', ')}" unless table

        insert_table(table)
        pending.delete(table)
      end
      account = Account.find(@mapping.fetch('accounts').fetch(@snapshot.fetch('source_account_id')))
      restore_display_ids(account)
      restore_managed_state(account) if @snapshot['managed_state']
      account
    end
  end

  private

  def restore_managed_state(account)
    state = @snapshot.fetch('managed_state')
    attributes = state.fetch('subscription').except('id', 'account_id').merge('account' => account)
    bytes = @snapshot.fetch('tables').fetch('active_storage_blobs', []).sum { |blob| blob.fetch('byte_size') }
    raise 'Restored attachments exceed the account storage limit' if bytes > attributes.fetch('storage_limit_bytes')

    subscription = Abera::Subscription.create!(attributes.merge('storage_reserved_bytes' => bytes))
    state.fetch('usage_windows').each do |window|
      subscription.usage_windows.create!(window.except('id', 'abera_subscription_id'))
    end
    restore_jobs(subscription, state)
  end

  def restore_jobs(subscription, state)
    state.fetch('pending_jobs').each do |work|
      # A restored client reconnects and reads fresh state. Old UI broadcasts
      # contain source record IDs and are not provider deliveries to replay.
      next if work.fetch('job_class') == 'ActionCableBroadcastJob'

      restore_job(subscription, work)
    end
    state.fetch('completed_webhooks', []).each { |work| restore_job(subscription, work) }
  end

  def restore_job(subscription, work)
    payload = remap_pending_job(work)
    key = Abera::JobIdentity.key(payload)
    state = work.fetch('state')
    state = 'pending' if %w[pending running].include?(state)
    attributes = work.except('id', 'abera_subscription_id').merge('state' => state,
                                                                  'arguments' => payload, 'deduplication_key' => key)
    subscription.durable_jobs.create!(attributes)
  end

  def remap_pending_job(work)
    payload = remap_job_arguments(work.fetch('arguments'))
    arguments = payload.fetch('arguments')
    if work.fetch('job_class') == 'ActionMailer::MailDeliveryJob' && arguments.first == 'ConversationReplyMailer'
      mail_arguments = arguments.fetch(3).fetch('args')
      mail_arguments[1] = @mapping.fetch('messages').fetch(mail_arguments.fetch(1))
    end
    Abera::JobReferences.remap!(work.fetch('job_class'), arguments, @mapping)
    payload
  end

  def remap_job_arguments(value)
    return value.map { |item| remap_job_arguments(item) } if value.is_a?(Array)
    return value unless value.is_a?(Hash)

    if value.key?('_aj_globalid')
      gid = GlobalID.parse(value.fetch('_aj_globalid'))
      model = gid.model_class
      record = model.find(@mapping.fetch(model.table_name).fetch(gid.model_id.to_i))
      return { '_aj_globalid' => record.to_global_id.to_s }
    end
    value.transform_values { |item| remap_job_arguments(item) }
  end

  def allocate_ids
    @snapshot.fetch('tables').each do |table, rows|
      model = @models.fetch(table)
      @mapping[table] = {}
      rows.each do |row|
        existing_user = User.from_email(row.fetch('email')) if table == 'users'
        if existing_user
          raise 'Existing user credentials differ from backup' unless existing_user.encrypted_password == row.fetch('encrypted_password')

          @mapping[table][row.fetch(model.primary_key)] = existing_user.id
          next
        end
        @mapping[table][row.fetch(model.primary_key)] = next_id(model)
      end
    end
    reuse_user_avatars
    reuse_access_tokens
  end

  def reuse_access_tokens
    @snapshot.fetch('tables').fetch('access_tokens', []).each do |source|
      existing = AccessToken.find_by(token: source.fetch('token'))
      next unless existing

      parent = source.fetch('owner_type').constantize.base_class
      target_id = @mapping.fetch(parent.table_name).fetch(source.fetch('owner_id'))
      raise 'Existing API token belongs to another identity' unless existing.owner_type == parent.name && existing.owner_id == target_id

      reuse_row('access_tokens', source.fetch('id'), existing.id)
    end
  end

  def reuse_user_avatars
    @snapshot.fetch('tables').fetch('active_storage_attachments', []).each do |attachment|
      next unless attachment.fetch('record_type') == 'User' && attachment.fetch('name') == 'avatar'

      user_id = @mapping.fetch('users').fetch(attachment.fetch('record_id'))
      existing = ActiveStorage::Attachment.find_by(record_type: 'User', record_id: user_id, name: 'avatar')
      next unless existing

      reuse_avatar(attachment, existing)
    end
  end

  def reuse_avatar(attachment, existing)
    source = @snapshot.fetch('tables').fetch('active_storage_blobs').find { |blob| blob.fetch('id') == attachment.fetch('blob_id') }
    raise 'Existing user avatar differs from backup' unless existing.blob.checksum == source.fetch('checksum')

    reuse_row('active_storage_attachments', attachment.fetch('id'), existing.id)
    reuse_row('active_storage_blobs', source.fetch('id'), existing.blob_id)
  end

  def reuse_row(table, source_id, target_id)
    @mapping.fetch(table)[source_id] = target_id
    @reused.add([table, target_id])
  end

  def next_id(model)
    connection = model.connection
    sequence = connection.select_value("SELECT pg_get_serial_sequence(#{connection.quote(model.table_name)}, #{connection.quote(model.primary_key)})")
    raise "Missing primary key sequence: #{model.table_name}" unless sequence

    connection.select_value("SELECT nextval(#{connection.quote(sequence)})").to_i
  end

  def dependencies(table)
    @models.fetch(table).reflect_on_all_associations(:belongs_to).flat_map do |association|
      if association.polymorphic?
        @snapshot.fetch('tables').fetch(table).filter_map { |row| row[association.foreign_type]&.constantize&.table_name }
      else
        association.klass.table_name
      end
    end.uniq
  end

  def insert_table(table)
    model = @models.fetch(table)
    @snapshot.fetch('tables').fetch(table).each do |source|
      target_id = @mapping.fetch(table).fetch(source.fetch(model.primary_key))
      next if table == 'users' && User.exists?(target_id)
      next if @reused.include?([table, target_id])

      attributes = import_attributes(model, source, target_id)
      # Restore exact stored values without callbacks that send messages or generate new channel tokens.
      # rubocop:disable Rails/SkipsModelValidations
      model.insert_all!([attributes])
      # rubocop:enable Rails/SkipsModelValidations
    end
  end

  def import_attributes(model, source, target_id)
    attributes = source.dup
    attributes[model.primary_key] = target_id
    model.reflect_on_all_associations(:belongs_to).each do |association|
      foreign_id = source[association.foreign_key]
      next if foreign_id.nil?

      parent = association.polymorphic? ? source.fetch(association.foreign_type).constantize : association.klass
      attributes[association.foreign_key] = @mapping.fetch(parent.table_name).fetch(foreign_id)
    end
    remap_blob_owner!(attributes) if model.table_name == 'active_storage_blobs'
    attributes
  end

  def remap_blob_owner!(attributes)
    attributes['key'] = "#{@blob_prefix}/#{SecureRandom.hex(16)}"
    owner = @snapshot['managed_state']&.dig('subscription', 'subscription_id')
    attributes['metadata'] = attributes.fetch('metadata').merge('abera_subscription_id' => owner) if owner
  end

  def restore_display_ids(account)
    { 'conversations' => 'conv', 'campaigns' => 'camp' }.each do |table, prefix|
      rows = @snapshot.fetch('tables').fetch(table, [])
      # PostgreSQL creation triggers generate display IDs; retain the identifiers from the backup.
      # rubocop:disable Rails/SkipsModelValidations
      rows.each { |row| @models.fetch(table).where(id: @mapping.fetch(table).fetch(row.fetch('id'))).update_all(display_id: row.fetch('display_id')) }
      # rubocop:enable Rails/SkipsModelValidations
      maximum = rows.map { |row| row.fetch('display_id') }.max || 1
      account.class.connection.execute("SELECT setval('#{prefix}_dpid_seq_#{account.id}', #{maximum}, #{rows.any?})")
    end
  end
end
