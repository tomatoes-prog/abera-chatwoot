require 'rails_helper'

RSpec.describe Abera::RateLimit do
  let(:subscription) { Struct.new(:subscription_id).new("atomic-#{SecureRandom.hex(8)}") }
  let(:redis) { Redis.new(Redis::Config.app) }

  before { allow(Redis::Alfred).to receive(:with).and_yield(redis) }

  after do
    redis.scan_each(match: "abera:#{subscription.subscription_id}:*") { |key| redis.del(key) }
    redis.close
  end

  it 'accepts exactly the configured number of requests under concurrent Redis increments' do
    freeze_time do
      decisions = Queue.new
      workers = 4.times.map do
        Thread.new { 20.times { decisions << described_class.allowed?(subscription, 'requests', 60) } }
      end
      workers.each(&:value)
      results = Array.new(80) { decisions.pop }
      expect(results.count(true)).to eq(60)
      expect(results.count(false)).to eq(20)
    end
  end
end
