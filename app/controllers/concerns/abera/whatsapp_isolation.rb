module Abera::WhatsappIsolation
  def process_payload
    return super unless Abera.enabled?

    payloads = Abera::WhatsappPayloads.split(params.to_unsafe_hash)
    payloads.each do |payload|
      account = Abera::WebhookContext.account(Webhooks::WhatsappEventsJob.new(payload))
      Abera::TenantGuard.check!(account)
    end
    return super if payloads.one? || inactive_whatsapp_number?

    # All changes must be durably accepted together before acknowledging Meta.
    ApplicationRecord.transaction do
      payloads.each { |payload| Webhooks::WhatsappEventsJob.perform_later(payload.to_h) }
    end
    head :ok
  end
end
