require 'rails_helper'

RSpec.describe Abera::AccountSnapshot do
  self.use_transactional_tests = false

  after do
    connection = ApplicationRecord.connection
    tables = connection.tables - %w[schema_migrations ar_internal_metadata]
    connection.execute("TRUNCATE #{tables.map { |table| connection.quote_table_name(table) }.join(', ')} CASCADE")
  end

  let(:account) { create(:account) }
  let(:neighbor) { create(:account) }
  let!(:conversation) { create(:conversation, account: account) }
  let!(:neighbor_conversation) { create(:conversation, account: neighbor) }
  let!(:message) { create(:message, account: account, conversation: conversation, inbox: conversation.inbox, content: 'Preserved message') }
  let!(:user) { create(:user, account: account, role: :administrator) }

  it 'exports the account graph without including its neighbor' do
    snapshot = described_class.new(account).export.deep_stringify_keys
    conversations = snapshot.fetch('tables').fetch('conversations')
    expect(conversations.map { |row| row.fetch('id') }).to eq([conversation.id])
    expect(snapshot.fetch('tables').fetch('users').map { |row| row.fetch('id') }).to eq([user.id])
    expect(snapshot.fetch('tables').fetch('messages').first.fetch('content')).to eq('Preserved message')
    expect(conversations).not_to include(hash_including('id' => neighbor_conversation.id))
  end

  it 'restores references into a new account and retains display IDs and credentials' do
    bot = create(:agent_bot, account: account)
    bot_token = bot.access_token.token
    snapshot = JSON.parse(JSON.generate(described_class.new(account).export))
    display_id = conversation.display_id
    email = user.email
    website_token = conversation.inbox.channel.website_token
    api_token = user.access_token.token
    Abera::RestoreCheck.new(snapshot).run do |restored|
      restored_conversation = restored.conversations.find_by!(display_id: display_id)
      expect(restored_conversation.messages.first.content).to eq('Preserved message')
      expect(restored_conversation.inbox.account_id).to eq(restored.id)
      expect(restored_conversation.contact.account_id).to eq(restored.id)
      expect(restored_conversation.inbox.channel.website_token).to eq(website_token)
      expect(restored.users.find_by!(email: email).valid_password?('Password1!')).to be(true)
      expect(restored.users.find_by!(email: email).access_token.token).to eq(api_token)
      expect(AgentBot.find_by!(account_id: restored.id, name: bot.name).access_token.token).to eq(bot_token)
    end
    expect(neighbor.reload.conversations).to include(neighbor_conversation)
  end

  it 'restores managed state, encrypted SMTP, usage and pending message references' do
    subscription = Abera::Subscription.create!(account: account, subscription_id: 'managed', customer_id: 'owner',
                                              service_host: 'managed.example.test', tier: 'professional', state: 'active')
    subscription.usage_windows.create!(starts_at: subscription.cycle_start, conversations: 150)
    Abera::SmtpSetting.create!(account: account, address: 'smtp.example.test', username: 'owner', password: 'Private-password1!',
                              sender: 'owner@example.test', port: 587, authentication: 'login', security: 'starttls')
    subscription.durable_jobs.create!(job_class: 'SendReplyJob', deduplication_key: 'pending-message',
                                     arguments: SendReplyJob.new(message.id).serialize, available_at: Time.current)
    subscription.durable_jobs.create!(job_class: 'ConversationReplyEmailJob', deduplication_key: 'pending-email',
                                     arguments: ConversationReplyEmailJob.new(conversation.id, message.id).serialize, available_at: Time.current)
    payload = Webhooks::TelegramEventsJob.new({ 'bot_token' => 'backup-bot', 'telegram' => { 'update_id' => 100 } }).serialize
    subscription.durable_jobs.create!(job_class: 'Webhooks::TelegramEventsJob', deduplication_key: Abera::JobIdentity.key(payload),
                                     arguments: payload, state: 'completed', available_at: Time.current, completed_at: Time.current)
    subscription.durable_jobs.create!(job_class: 'Abera::SmtpTestJob', deduplication_key: 'failed-smtp-test',
                                     arguments: Abera::SmtpTestJob.new(account.id, user.id).serialize, state: 'failed',
                                     available_at: Time.current, attempts: 1, last_error: 'Net::SMTPAuthenticationError')
    snapshot = JSON.parse(JSON.generate(described_class.new(account).export))
    Abera::RestoreCheck.new(snapshot).run do |restored|
      restored_subscription = restored.abera_subscription
      expect(restored_subscription.subscription_id).to eq('managed')
      expect(restored_subscription.usage_windows.first.conversations).to eq(150)
      completed = restored_subscription.durable_jobs.find_by!(job_class: 'Webhooks::TelegramEventsJob')
      expect(completed.state).to eq('completed')
      failed = restored_subscription.durable_jobs.find_by!(job_class: 'Abera::SmtpTestJob')
      expect(failed.state).to eq('failed')
      expect(failed.last_error).to eq('Net::SMTPAuthenticationError')
      expect(completed.deduplication_key).to eq(Abera::JobIdentity.key(payload))
      expect(restored.abera_smtp_setting.password).to eq('Private-password1!')
      work = restored_subscription.durable_jobs.find_by!(job_class: 'SendReplyJob')
      restored_message = restored.messages.find_by!(content: 'Preserved message')
      expect(work.arguments.fetch('arguments').first).to eq(restored_message.id)
      expect(work.state).to eq('pending')
      email_work = restored_subscription.durable_jobs.find_by!(job_class: 'ConversationReplyEmailJob')
      expect(email_work.arguments.fetch('arguments')).to eq([restored_message.conversation_id, restored_message.id])
    end
    expect(neighbor.reload.conversations).to include(neighbor_conversation)
  ensure
    Redis::Alfred.delete("abera:dispatch:#{subscription.id}") if subscription
  end

  it 'reuses a shared user avatar when restoring into its original group' do
    AccountUser.create!(account: neighbor, user: user, role: :agent)
    with_modified_env(ABERA_MANAGED: 'false') do
      File.open(Rails.root.join('spec/assets/avatar.png')) do |file|
        user.avatar.attach(io: file, filename: 'avatar.png', content_type: 'image/png')
      end
    end
    avatar_id = user.avatar.blob.id
    subscription = Abera::Subscription.create!(account: account, subscription_id: 'avatar-restore', customer_id: 'owner',
                                              service_host: 'avatar.example.test', tier: 'essential', state: 'quiescing')
    snapshot = JSON.parse(JSON.generate(described_class.new(account).export))
    restored = ApplicationRecord.transaction do
      Abera::AccountRemoval.new(subscription).run
      Abera::AccountImport.new(snapshot).restore!
    end
    expect(restored.users.find(user.id).avatar.blob.id).to eq(avatar_id)
    expect(neighbor.reload.users.find(user.id).avatar.blob.id).to eq(avatar_id)
    expect(ActiveStorage::Attachment.where(record_type: 'User', record_id: user.id, name: 'avatar').count).to eq(1)
    expect(neighbor.conversations).to include(neighbor_conversation)
  end
end
