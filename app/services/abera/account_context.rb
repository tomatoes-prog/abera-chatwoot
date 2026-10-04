class Abera::AccountContext
  def self.resolve(value)
    case value
    when Account then value
    # Users are shared identities. Their current membership is not ownership
    # of a mail or job payload; use the explicit account or resource instead.
    when User then nil
    when Array then unique_account(value.filter_map { |item| resolve(item) })
    when Hash then resolve(value.values)
    else value.account if value.respond_to?(:account)
    end
  end

  def self.unique_account(accounts)
    raise ActiveRecord::RecordNotFound if accounts.map(&:id).uniq.size > 1

    accounts.first
  end
  private_class_method :unique_account
end
