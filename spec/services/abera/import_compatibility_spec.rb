require 'rails_helper'

RSpec.describe Abera::ImportCompatibility do
  let!(:user) { create(:user) }
  let(:source) { { 'id' => 901, 'email' => user.email, 'encrypted_password' => user.encrypted_password } }
  let(:snapshot) { { 'tables' => { 'users' => [source] } } }

  it 'allows reuse of an existing identity without changing its credentials' do
    expect(described_class.eligible?(snapshot)).to be(true)
    expect(user.reload.encrypted_password).to eq(source.fetch('encrypted_password'))
  end

  it 'rejects a group whose existing user has another password hash' do
    original = user.encrypted_password
    source['encrypted_password'] = 'another-password-hash'
    expect(described_class.eligible?(snapshot)).to be(false)
    expect(user.reload.encrypted_password).to eq(original)
  end

  it 'allows an identity that does not yet exist in the destination' do
    source['email'] = 'new-owner@example.test'
    expect(described_class.eligible?(snapshot)).to be(true)
    expect(User.from_email('new-owner@example.test')).to be_nil
  end

  it 'reuses the same API token without changing its owner' do
    token = user.access_token
    snapshot.fetch('tables')['access_tokens'] = [{ 'id' => 902, 'owner_type' => 'User', 'owner_id' => 901, 'token' => token.token }]
    expect(described_class.eligible?(snapshot)).to be(true)
    expect(token.reload.owner).to eq(user)
  end

  it 'rejects a different API token even when password credentials match' do
    snapshot.fetch('tables')['access_tokens'] = [{ 'id' => 902, 'owner_type' => 'User', 'owner_id' => 901, 'token' => 'source-api-token' }]
    original = user.access_token.token
    expect(described_class.eligible?(snapshot)).to be(false)
    expect(user.access_token.reload.token).to eq(original)
  end

  it 'rejects importing a second token for an existing identity' do
    original = user.access_token.token
    backup = { 'schema_version' => 1, 'tables' => snapshot.fetch('tables') }
    backup.fetch('tables')['access_tokens'] = [{ 'id' => 902, 'owner_type' => 'User', 'owner_id' => 901, 'token' => 'old-api-token' }]
    expect { Abera::AccountImport.new(backup).restore! }.to raise_error('Existing account identities differ from backup')
    expect(user.access_token.reload.token).to eq(original)
    expect(AccessToken.where(owner: user).count).to eq(1)
  end
end
