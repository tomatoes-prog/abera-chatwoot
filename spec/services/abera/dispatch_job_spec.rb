require 'rails_helper'

RSpec.describe Abera::DispatchJob do
  let(:first) do
    Abera::Subscription.create!(account: create(:account), subscription_id: 'first', customer_id: 'owner-first',
                               service_host: 'first.example.test', tier: 'essential', state: 'active')
  end
  let(:second) do
    Abera::Subscription.create!(account: create(:account), subscription_id: 'second', customer_id: 'owner-second',
                               service_host: 'second.example.test', tier: 'essential', state: 'active')
  end

  after do
    Redis::Alfred.delete("abera:dispatch:#{first.id}")
    Redis::Alfred.delete("abera:dispatch:#{second.id}")
    clear_enqueued_jobs
    Current.reset
    Abera::Current.reset
  end

  it 'keeps only one dispatch in the queue per account while another account can enqueue' do
    clear_enqueued_jobs
    20.times { described_class.enqueue(first.id) }
    described_class.enqueue(second.id)
    dispatches = enqueued_jobs.select { |job| job[:job] == described_class }
    expect(dispatches.map { |job| job[:args].first }).to contain_exactly(first.id, second.id)
  end

  it 'can schedule durable work again after the Redis scheduling pointer is lost' do
    described_class.enqueue(first.id)
    Redis::Alfred.delete("abera:dispatch:#{first.id}")
    clear_enqueued_jobs
    described_class.enqueue(first.id)
    dispatches = enqueued_jobs.select { |job| job[:job] == described_class }
    expect(dispatches.map { |job| job[:args].first }).to eq([first.id])
  end
end
