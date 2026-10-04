# frozen_string_literal: true

module Abera
  def self.enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('ABERA_MANAGED', false))
  end
end
