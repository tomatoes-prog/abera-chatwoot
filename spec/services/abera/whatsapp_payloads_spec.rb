require 'rails_helper'

RSpec.describe Abera::WhatsappPayloads do
  it 'preserves every change and its enclosing entry when splitting a Meta batch' do
    payload = { 'object' => 'whatsapp_business_account', 'phone_number' => '123',
                'entry' => [{ 'id' => 'entry-one', 'changes' => [{ 'value' => { 'id' => 'one' } }, { 'value' => { 'id' => 'two' } }] },
                            { 'id' => 'entry-two', 'changes' => [{ 'value' => { 'id' => 'three' } }] }] }
    events = described_class.split(payload)
    expect(events.map { |event| event.dig(:entry, 0, :changes, 0, :value, :id) }).to eq(%w[one two three])
    expect(events.map { |event| event.dig(:entry, 0, :id) }).to eq(%w[entry-one entry-one entry-two])
    expect(events.map { |event| event[:phone_number] }).to eq(%w[123 123 123])
    expect(payload.fetch('entry').first.fetch('changes').size).to eq(2)
  end

  it 'rejects an empty Meta batch instead of acknowledging and dropping it' do
    expect { described_class.split('object' => 'whatsapp_business_account', 'entry' => []) }.to raise_error(ArgumentError)
  end

  it 'retains the native payload for other WhatsApp providers' do
    expect(described_class.split('phone_number' => '123', 'messages' => [{ 'id' => 'one' }]).size).to eq(1)
  end
end
