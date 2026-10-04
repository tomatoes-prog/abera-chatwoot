class Abera::WhatsappPayloads
  def self.split(payload)
    payload = payload.with_indifferent_access
    return [payload] unless payload[:object] == 'whatsapp_business_account'

    entries = payload.fetch(:entry)
    raise ArgumentError, 'Empty WhatsApp batch' if entries.empty?

    entries.flat_map do |entry|
      entry = entry.with_indifferent_access
      changes = entry.fetch(:changes)
      raise ArgumentError, 'Empty WhatsApp entry' if changes.empty?

      changes.map { |change| payload.merge(entry: [entry.merge(changes: [change])]) }
    end
  end
end
