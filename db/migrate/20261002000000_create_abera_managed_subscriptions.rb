class CreateAberaManagedSubscriptions < ActiveRecord::Migration[7.1]
  def change
    create_subscriptions
    create_usage_windows
    create_smtp_settings
    create_durable_jobs
    create_operation_receipts
  end

  private

  def create_subscriptions
    create_table :abera_subscriptions do |t|
      t.references :account, null: false, foreign_key: true, index: { unique: true }
      t.string :subscription_id, null: false
      t.string :customer_id, null: false
      t.string :service_host, null: false
      t.string :tier, null: false
      t.string :state, null: false, default: 'pending'
      t.string :activation_token_digest
      t.string :admin_email
      t.datetime :activated_at
      t.datetime :activation_consumed_at
      subscription_limits(t)
      t.timestamps
    end
    add_index :abera_subscriptions, :subscription_id, unique: true
    add_index :abera_subscriptions, :service_host, unique: true
    add_index :abera_subscriptions, :activation_token_digest, unique: true
  end

  def subscription_limits(table)
    table.integer :agent_limit, null: false, default: 2
    table.integer :conversation_limit, null: false, default: 500
    table.bigint :storage_limit_bytes, null: false, default: 2.gigabytes
    table.bigint :storage_reserved_bytes, null: false, default: 0
  end

  def create_usage_windows
    create_table :abera_usage_windows do |t|
      t.references :abera_subscription, null: false, foreign_key: true
      t.datetime :starts_at, null: false
      t.integer :conversations, null: false, default: 0
      t.timestamps
    end
    add_index :abera_usage_windows, [:abera_subscription_id, :starts_at], unique: true, name: 'index_abera_usage_window'
  end

  def create_smtp_settings
    create_table :abera_smtp_settings do |t|
      t.references :account, null: false, foreign_key: true, index: { unique: true }
      t.string :address, null: false
      t.integer :port, null: false, default: 587
      t.string :username, null: false
      t.text :password, null: false
      t.string :sender, null: false
      t.string :authentication, null: false, default: 'login'
      t.string :security, null: false, default: 'starttls'
      t.timestamps
    end
  end

  def create_durable_jobs
    create_table :abera_durable_jobs do |t|
      t.references :abera_subscription, null: false, foreign_key: true
      t.string :job_class, null: false
      t.string :deduplication_key, null: false
      t.jsonb :arguments, null: false
      t.string :state, null: false, default: 'pending'
      t.string :lease_owner
      t.datetime :lease_until
      t.datetime :available_at, null: false
      t.datetime :completed_at
      t.integer :attempts, null: false, default: 0
      t.text :last_error
      t.timestamps
    end
    add_index :abera_durable_jobs, [:abera_subscription_id, :deduplication_key], unique: true, name: 'index_abera_durable_deduplication'
    add_index :abera_durable_jobs, [:state, :available_at]
  end

  def create_operation_receipts
    create_table :abera_operation_receipts do |t|
      t.string :operation_id, null: false
      t.string :subscription_id, null: false
      t.string :action, null: false
      t.jsonb :result, null: false
      t.text :credentials
      t.timestamps
    end
    add_index :abera_operation_receipts, [:operation_id, :action], unique: true
  end
end
