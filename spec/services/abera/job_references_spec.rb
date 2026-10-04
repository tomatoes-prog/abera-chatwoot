require 'rails_helper'

RSpec.describe Abera::JobReferences do
  it 'remaps an inbox identifier without changing its scheduling token' do
    arguments = [{ 'inbox_id' => 10, 'token' => 'source-token', '_aj_ruby2_keywords' => %w[inbox_id token] }]
    described_class.remap!('AutoAssignment::AssignmentJob', arguments, { 'inboxes' => { 10 => 20 } })
    expect(arguments.first.fetch('inbox_id')).to eq(20)
    expect(arguments.first.fetch('token')).to eq('source-token')
  end

  it 'leaves the IMAP polling interval unchanged' do
    arguments = [{ '_aj_globalid' => 'gid://chatwoot/Channel::Email/20' }, 1]
    described_class.remap!('Inboxes::FetchImapEmailsJob', arguments, {})
    expect(arguments.last).to eq(1)
  end

  it 'remaps mention users and conversation and account identifiers' do
    arguments = [[10, 11], 20, 30]
    described_class.remap!('Conversations::UserMentionJob', arguments,
                          { 'users' => { 10 => 110, 11 => 111 }, 'conversations' => { 20 => 120 }, 'accounts' => { 30 => 130 } })
    expect(arguments).to eq([[110, 111], 120, 130])
  end

  it 'resolves a scheduled inbox account without mutating the job arguments' do
    inbox = create(:inbox)
    job = AutoAssignment::AssignmentJob.new(inbox_id: inbox.id, token: 'scheduled-token')
    original = job.arguments.deep_dup
    expect(described_class.account(job)).to eq(inbox.account)
    expect(job.arguments).to eq(original)
  end

  it 'remaps bulk contact IDs while preserving labels and the requested action' do
    arguments = [10, 20, { 'ids' => ['30', 31], 'labels' => { 'add' => ['vip'] }, 'action_name' => 'delete' }]
    described_class.remap!('Contacts::BulkActionJob', arguments,
                          { 'accounts' => { 10 => 110 }, 'users' => { 20 => 120 }, 'contacts' => { 30 => 130, 31 => 131 } })
    expect(arguments).to eq([110, 120, { 'ids' => [130, 131], 'labels' => { 'add' => ['vip'] }, 'action_name' => 'delete' }])
  end

  it 'rejects a bulk action containing a contact from another account before enqueueing' do
    account = create(:account)
    user = create(:user, account: account)
    foreign_contact = create(:contact)
    job = Contacts::BulkActionJob.new(account.id, user.id, { ids: [foreign_contact.id], action_name: 'delete' })
    expect { described_class.account(job) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it 'retains conversation display IDs used by macros' do
    arguments = [{ '_aj_globalid' => 'gid://chatwoot/Macro/10' }, { 'conversation_ids' => [20, 21] }]
    described_class.remap!('MacrosExecutionJob', arguments, {})
    expect(arguments.last.fetch('conversation_ids')).to eq([20, 21])
  end
end
