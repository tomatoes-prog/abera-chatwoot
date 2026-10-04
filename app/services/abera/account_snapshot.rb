class Abera::AccountSnapshot
  GLOBAL_ROOTS = %w[users tags active_storage_blobs agent_bots].freeze
  EXCLUDED = %w[abera_operation_receipts abera_subscriptions abera_durable_jobs abera_usage_windows user_sessions].freeze

  def initialize(account)
    @account = account
    Rails.application.eager_load!
    @models = ActiveRecord::Base.descendants.reject(&:abstract_class?).select(&:table_exists?).map(&:base_class).uniq.index_by(&:table_name)
    @rows = Hash.new { |hash, table| hash[table] = {} }
  end

  def export
    options = ApplicationRecord.connection.transaction_open? ? {} : { isolation: :repeatable_read }
    ApplicationRecord.transaction(**options) do
      add(Account, Account.where(id: @account.id))
      collect_account_rows
      check_unmapped_tables!
      loop do
        count = @rows.values.sum(&:size)
        expand_references
        break if count == @rows.values.sum(&:size)
      end
      { schema_version: 1, source_account_id: @account.id, managed_state: managed_state,
        tables: @rows.reject { |_table, records| records.empty? }.transform_values(&:values) }
    end
  end

  private

  def collect_account_rows
    @models.each_value do |model|
      next if EXCLUDED.include?(model.table_name) || model.column_names.exclude?('account_id')

      add(model, model.where(account_id: @account.id))
    end
  end

  def managed_state
    managed = Abera::Subscription.find_by(account_id: @account.id)
    return unless managed

    { subscription: managed.attributes, usage_windows: managed.usage_windows.map(&:attributes),
      pending_jobs: managed.durable_jobs.where(state: %w[pending running failed]).map(&:attributes),
      completed_webhooks: managed.durable_jobs.where(state: 'completed').where("job_class LIKE 'Webhooks::%'").map(&:attributes) }
  end

  def add(model, records)
    records.each do |record|
      check_ownership!(model, record)

      attributes = record.attributes.slice(*model.column_names)
      attributes['tokens'] = {} if model.table_name == 'users'
      attributes['reset_password_token'] = nil if model.table_name == 'users'
      @rows[model.table_name][record.id] = attributes
    end
  end

  def check_ownership!(model, record)
    raise 'Cross-account backup reference' if record.has_attribute?(:account_id) && record.account_id != @account.id
    raise 'Cross-account backup root' if model.table_name == 'accounts' && record.id != @account.id
  end

  def expand_references
    @models.each_value do |model|
      next if EXCLUDED.include?(model.table_name)

      model.reflect_on_all_associations(:belongs_to).each do |association|
        if association.polymorphic?
          expand_polymorphic(model, association)
        else
          expand_foreign_key(model, association)
        end
      end
    end
    collect_attachments
    collect_access_tokens
  end

  def collect_access_tokens
    { 'users' => 'User', 'agent_bots' => 'AgentBot' }.each do |table, type|
      add(AccessToken, AccessToken.where(owner_type: type, owner_id: @rows[table].keys))
    end
  end

  def expand_foreign_key(model, association)
    parent = association.klass
    return unless parent < ActiveRecord::Base && parent.table_exists?

    forward_ids = @rows[model.table_name].values.filter_map { |row| row[association.foreign_key] }.uniq
    collect_foreign_parents(parent, forward_ids)
    return if GLOBAL_ROOTS.include?(parent.table_name) || model.column_names.include?('account_id')

    parent_ids = @rows[parent.table_name].keys
    add(model, model.where(association.foreign_key => parent_ids)) if parent_ids.any?
  end

  def collect_foreign_parents(parent, ids)
    return if ids.empty? || EXCLUDED.include?(parent.table_name)

    add(parent, parent.where(parent.primary_key => ids))
  end

  def collect_attachments
    @rows.to_a.each do |table, records|
      next if table.start_with?('active_storage_')

      model = @models.fetch(table)
      attachments = ActiveStorage::Attachment.where(record_type: model.base_class.name, record_id: records.keys)
      add(ActiveStorage::Attachment, attachments)
    end
  end

  def expand_polymorphic(model, association)
    collect_polymorphic_parents(model, association)
    collect_polymorphic_children(model, association)
  end

  def collect_polymorphic_parents(model, association)
    @rows[model.table_name].values.group_by { |row| row[association.foreign_type] }.each do |type, rows|
      next if type.blank?

      parent = type.constantize.base_class
      ids = rows.filter_map { |row| row[association.foreign_key] }
      add(parent, parent.where(parent.primary_key => ids)) unless EXCLUDED.include?(parent.table_name)
    end
  end

  def collect_polymorphic_children(model, association)
    @rows.to_a.each do |table, records|
      next if GLOBAL_ROOTS.include?(table) || EXCLUDED.include?(table)

      parent = @models.fetch(table)
      add(model, model.where(association.foreign_type => parent.base_class.name, association.foreign_key => records.keys))
    end
  end

  def check_unmapped_tables!
    connection = ApplicationRecord.connection
    connection.tables.each do |table|
      next if @models.key?(table) || connection.columns(table).none? { |column| column.name == 'account_id' }

      quoted = connection.quote_table_name(table)
      raise "Backup model missing for #{table}" if connection.select_value("SELECT 1 FROM #{quoted} WHERE account_id = #{@account.id} LIMIT 1")
    end
  end
end
