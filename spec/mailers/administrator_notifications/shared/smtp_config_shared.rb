# frozen_string_literal: true

RSpec.shared_context 'with smtp config' do
  around do |example|
    with_modified_env(SMTP_ADDRESS: 'smtp.example.test') { example.run }
  end
end
