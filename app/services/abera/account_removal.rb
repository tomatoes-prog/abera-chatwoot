class Abera::AccountRemoval
  def initialize(subscription)
    @subscription = subscription
    @account = subscription.account
    @connection = ApplicationRecord.connection
  end

  # Called inside Administration's transaction, after draining tenant writers.
  # Native destroy_async callbacks would outlive the reservation and can send mail.
  def run
    raise 'Account must be quiesced before removal' unless @subscription.state == 'quiescing'

    tables = Abera::AccountSnapshot.new(@account).export.deep_stringify_keys.fetch('tables')
    @rows = removable_rows(tables)
    blob_keys = @rows.fetch('active_storage_blobs', []).map { |blob| blob.fetch('key') }
    remove_managed_state
    remove_rows
    %w[conv camp].each { |prefix| @connection.execute("DROP SEQUENCE IF EXISTS #{prefix}_dpid_seq_#{@account.id}") }
    { 'subscriptionId' => @subscription.subscription_id, 'customerId' => @subscription.customer_id,
      'accountId' => @account.id, 'state' => 'absent', 'attachmentKeys' => blob_keys }
  end

  private

  def removable_rows(tables)
    protected = %w[users tags]
    rows = tables.except(*protected)
    rows['agent_bots'] = rows.fetch('agent_bots', []).select { |row| row['account_id'] == @account.id }
    bots = rows.fetch('agent_bots').pluck('id')
    rows['access_tokens'] = rows.fetch('access_tokens', []).select { |row| row['owner_type'] == 'AgentBot' && bots.include?(row['owner_id']) }
    filter_attachment_rows(rows)
    rows.reject { |_table, records| records.empty? }
  end

  def filter_attachment_rows(rows)
    rows['active_storage_attachments'] = rows.fetch('active_storage_attachments', []).reject { |row| row['record_type'] == 'User' }
    attachments = rows.fetch('active_storage_attachments').map { |row| row.fetch('id') }
    rows['active_storage_blobs'] = rows.fetch('active_storage_blobs', []).select do |blob|
      ActiveStorage::Attachment.where(blob_id: blob.fetch('id')).where.not(id: attachments).none?
    end
    blob_ids = rows.fetch('active_storage_blobs').map { |row| row.fetch('id') }
    rows['active_storage_variant_records'] = rows.fetch('active_storage_variant_records', []).select { |row| blob_ids.include?(row.fetch('blob_id')) }
  end

  def remove_managed_state
    # rubocop:disable Rails/SkipsModelValidations
    @subscription.durable_jobs.delete_all
    @subscription.usage_windows.delete_all
    Abera::Subscription.where(id: @subscription.id).delete_all
    Abera::OperationReceipt.where(subscription_id: @subscription.subscription_id).update_all(credentials: nil)
    AccessToken.where(owner_type: 'AgentBot', owner_id: @rows.fetch('agent_bots', []).pluck('id')).delete_all
    # rubocop:enable Rails/SkipsModelValidations
  end

  def remove_rows
    pending = @rows.keys
    until pending.empty?
      table = pending.find { |candidate| pending.none? { |child| references_table?(child, candidate) } }
      raise "Unresolved removal dependencies: #{pending.join(', ')}" unless table

      ids = @rows.fetch(table).map { |row| Integer(row.fetch('id')) }
      @connection.execute("DELETE FROM #{@connection.quote_table_name(table)} WHERE id IN (#{ids.join(',')})")
      pending.delete(table)
    end
  end

  def references_table?(child, candidate)
    child != candidate && @connection.foreign_keys(child).any? { |key| key.to_table == candidate }
  end
end
