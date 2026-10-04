class Abera::ImportCompatibility
  def self.assert_eligible!(snapshot)
    raise 'Existing account identities differ from backup' unless eligible?(snapshot)
  end

  def self.eligible?(snapshot)
    tables = snapshot.fetch('tables')
    identities = tables.fetch('users', []).all? do |source|
      existing = User.from_email(source.fetch('email'))
      next true unless existing
      next false unless existing.encrypted_password == source.fetch('encrypted_password')

      avatar_matches?(existing, source, tables)
    end
    identities && tokens_match?(tables)
  end

  def self.tokens_match?(tables)
    tables.fetch('access_tokens', []).all? do |source|
      target = target_user(source, tables)
      existing = AccessToken.find_by(token: source.fetch('token'))
      if existing
        target && existing.owner_type == 'User' && existing.owner_id == target.id
      else
        !target || target.access_token.nil?
      end
    end
  end

  def self.target_user(source, tables)
    return unless source.fetch('owner_type') == 'User'

    user = tables.fetch('users').find { |row| row.fetch('id') == source.fetch('owner_id') }
    User.from_email(user.fetch('email'))
  end

  def self.avatar_matches?(existing, source, tables)
    avatar = tables.fetch('active_storage_attachments', []).find do |attachment|
      attachment.fetch('record_type') == 'User' && attachment.fetch('record_id') == source.fetch('id') && attachment.fetch('name') == 'avatar'
    end
    return true unless avatar && existing.avatar.attached?

    blob = tables.fetch('active_storage_blobs').find { |row| row.fetch('id') == avatar.fetch('blob_id') }
    existing.avatar.blob.checksum == blob.fetch('checksum')
  end
end
