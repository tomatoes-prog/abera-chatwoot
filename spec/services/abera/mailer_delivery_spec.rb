require 'rails_helper'

RSpec.describe Abera::MailerDelivery do
  let(:account) { create(:account) }
  let(:neighbor) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:neighbor_user) { create(:user, account: neighbor) }

  before do
    [[account, 'one'], [neighbor, 'two']].each do |owner, name|
      Abera::Subscription.create!(account: owner, subscription_id: name, customer_id: "owner-#{name}",
                                  service_host: "#{name}.example.test", tier: 'essential', state: 'active')
      Abera::SmtpSetting.create!(account: owner, address: "smtp.#{name}.example.test", port: 587, username: name,
                                 password: "Private-#{name}-password1!", sender: "#{name}@example.test",
                                 authentication: 'login', security: 'starttls')
    end
  end

  after { Current.reset }

  it 'uses each account SMTP and domain for password recovery despite another current account', :aggregate_failures do
    Current.account = neighbor
    first = Devise.mailer.with(account: account).reset_password_instructions(user, 'first-token').message
    second = Devise.mailer.with(account: neighbor).reset_password_instructions(neighbor_user, 'second-token').message
    expect(first.delivery_method.settings[:address]).to eq('smtp.one.example.test')
    expect(second.delivery_method.settings[:address]).to eq('smtp.two.example.test')
    expect(first.from).to eq(['one@example.test'])
    expect(second.from).to eq(['two@example.test'])
    expect(first.body.decoded).to include('https://one.example.test/app/auth/password/edit')
    expect(second.body.decoded).to include('https://two.example.test/app/auth/password/edit')
    expect(Current.account).to eq(neighbor)
    expect(first.delivery_method.settings[:openssl_verify_mode]).to eq('peer')
  end

  it 'does not construct an outgoing authentication email before SMTP is configured', :aggregate_failures do
    account.abera_smtp_setting.destroy!
    account.reload
    mail = Devise.mailer.with(account: account).reset_password_instructions(user, 'token').message
    expect(mail).to be_a(ActionMailer::Base::NullMail)
  end

  it 'uses the explicit account SMTP when the same user belongs to two accounts', :aggregate_failures do
    AccountUser.create!(account: neighbor, user: user, role: :agent)
    Current.account = neighbor
    mail = Devise.mailer.with(account: account).reset_password_instructions(user, 'shared-token').message
    expect(mail.delivery_method.settings[:address]).to eq('smtp.one.example.test')
    expect(mail.from).to eq(['one@example.test'])
    expect(mail.body.decoded).to include('https://one.example.test/app/auth/password/edit')
    expect(Current.account).to eq(neighbor)
  end
end
