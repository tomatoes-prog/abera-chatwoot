require 'rails_helper'

RSpec.describe Abera::JobIdentity do
  it 'deduplicates repeated webhook payloads regardless of hash insertion order or generated job ID' do
    original = Webhooks::TelegramEventsJob.new({ 'bot_token' => 'own-bot', 'update_id' => 100 }).serialize
    retry_payload = Webhooks::TelegramEventsJob.new({ 'update_id' => 100, 'bot_token' => 'own-bot' }).serialize
    expect(original.fetch('job_id')).not_to eq(retry_payload.fetch('job_id'))
    expect(described_class.key(original)).to eq(described_class.key(retry_payload))
  end

  it 'keeps different provider events and ActiveJob retries separate' do
    original = Webhooks::TelegramEventsJob.new({ 'bot_token' => 'own-bot', 'update_id' => 100 }).serialize
    another = Webhooks::TelegramEventsJob.new({ 'bot_token' => 'own-bot', 'update_id' => 101 }).serialize
    expect(described_class.key(original)).not_to eq(described_class.key(another))
    expect(described_class.key(original)).not_to eq(described_class.key(original.merge('executions' => 1)))
  end

  it 'uses the Telegram update identity despite changes to non-identity request metadata' do
    original = Webhooks::TelegramEventsJob.new({ 'bot_token' => 'own-bot', 'telegram' => { 'update_id' => 100 }, 'format' => 'json' }).serialize
    repeated = Webhooks::TelegramEventsJob.new({ 'bot_token' => 'own-bot', 'telegram' => { 'update_id' => 100 }, 'format' => 'html' }).serialize
    expect(described_class.key(original)).to eq(described_class.key(repeated))
    another_bot = repeated.deep_dup
    another_bot.fetch('arguments').first['bot_token'] = 'other-bot'
    expect(described_class.key(original)).not_to eq(described_class.key(another_bot))
  end
end
