require 'rails_helper'

RSpec.describe Abera::TenantLock do
  let(:subscription) do
    Abera::Subscription.create!(account: create(:account), subscription_id: 'lock-one', customer_id: 'owner-one',
                                service_host: 'lock.example.test', tier: 'essential', state: 'active')
  end

  it 'holds off an exclusive lifecycle operation while allowing another subscription to proceed' do
    configuration = ApplicationRecord.connection_db_config.configuration_hash
    control = PG.connect(host: configuration.fetch(:host), port: configuration[:port],
                         dbname: configuration.fetch(:database), user: configuration.fetch(:username), password: configuration[:password])
    own_key = described_class.key(subscription.subscription_id)
    neighbor_key = described_class.key('lock-neighbor')
    described_class.with_access(subscription) do
      expect(control.exec("SELECT pg_try_advisory_lock(#{own_key})").getvalue(0, 0)).to eq('f')
      expect(control.exec("SELECT pg_try_advisory_lock(#{neighbor_key})").getvalue(0, 0)).to eq('t')
      control.exec("SELECT pg_advisory_unlock(#{neighbor_key})")
    end
    expect(control.exec("SELECT pg_try_advisory_lock(#{own_key})").getvalue(0, 0)).to eq('t')
  ensure
    control&.close
  end

  it 'releases the access lock when the application raises an exception' do
    expect do
      described_class.with_access(subscription) { raise ArgumentError, 'request failed' }
    end.to raise_error(ArgumentError, 'request failed')
    connection = ApplicationRecord.connection
    locks = connection.select_value("SELECT COUNT(*) FROM pg_locks WHERE pid = pg_backend_pid() AND locktype = 'advisory'").to_i
    expect(locks).to eq(0)
  end
end
