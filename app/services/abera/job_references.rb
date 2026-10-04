class Abera::JobReferences
  POSITIONAL = {
    'SendReplyJob' => { 0 => 'messages' },
    'ConversationReplyEmailJob' => { 0 => 'conversations', 1 => 'messages' },
    'Conversations::UpdateMessageStatusJob' => { 0 => 'conversations' },
    'Conversations::UserMentionJob' => { 0 => 'users', 1 => 'conversations', 2 => 'accounts' },
    'Account::ContactsExportJob' => { 0 => 'accounts', 1 => 'users' },
    'Contacts::BulkActionJob' => { 0 => 'accounts', 1 => 'users' },
    'Account::BrandingEnrichmentJob' => { 0 => 'accounts' },
    'Companies::FetchAvatarsJob' => { 0 => 'accounts' },
    'Crm::SetupJob' => { 0 => 'integrations_hooks' },
    'Labels::UpdateJob' => { 2 => 'accounts' },
    'Abera::SmtpTestJob' => { 0 => 'accounts', 1 => 'users' }
  }.freeze
  KEYWORDS = {
    'AutoAssignment::AssignmentJob' => { 'inbox_id' => 'inboxes' },
    'Labels::RemoveAssociationsJob' => { 'account_id' => 'accounts' }
  }.freeze

  def self.account(job)
    references = []
    map_references!(job.class.name, job.arguments.deep_dup) do |table, value|
      model = POSITIONAL_MODELS.fetch(table)
      references.concat(Array(model.find(value)))
      value
    end
    Abera::AccountContext.resolve(references)
  end

  def self.remap!(name, arguments, mapping)
    map_references!(name, arguments) do |table, value|
      ids = mapping.fetch(table)
      value.is_a?(Array) ? value.map { |id| ids.fetch(id.to_i) } : ids.fetch(value.to_i)
    end
  end

  def self.map_references!(name, arguments)
    POSITIONAL.fetch(name, {}).each do |index, table|
      arguments[index] = yield table, arguments.fetch(index)
    end
    if name == 'Contacts::BulkActionJob'
      attributes = arguments.fetch(2)
      contact_key = attributes.key?('ids') ? 'ids' : :ids
      attributes[contact_key] = yield 'contacts', attributes.fetch(contact_key) if attributes.key?(contact_key)
    end
    KEYWORDS.fetch(name, {}).each do |key, table|
      attributes = arguments.last
      actual_key = attributes.key?(key) ? key : key.to_sym
      attributes[actual_key] = yield table, attributes.fetch(actual_key)
    end
  end
  private_class_method :map_references!

  POSITIONAL_MODELS = {
    'accounts' => Account, 'users' => User, 'inboxes' => Inbox,
    'contacts' => Contact, 'messages' => Message, 'conversations' => Conversation, 'integrations_hooks' => Integrations::Hook
  }.freeze
end
