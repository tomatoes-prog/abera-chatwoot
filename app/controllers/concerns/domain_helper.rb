module DomainHelper
  def self.chatwoot_domain?(domain = request.host)
    [URI.parse(ChatwootApp.frontend_url(default: '')).host, URI.parse(ENV.fetch('HELPCENTER_URL', '')).host].include?(domain)
  end
end
