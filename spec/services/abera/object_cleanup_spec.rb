require 'rails_helper'

RSpec.describe Abera::ObjectCleanup do
  let(:storage) { Aws::S3::Client.new(stub_responses: true) }

  around { |example| with_modified_env(S3_BUCKET_NAME: 'private-files') { example.run } }

  it 'erases exact keys and their versions without deleting keys that share a prefix' do
    storage.stub_responses(:list_object_versions,
                           versions: [{ key: 'own-key', version_id: 'one' }, { key: 'own-key-neighbor', version_id: 'neighbor' }],
                           delete_markers: [{ key: 'own-key', version_id: 'marker' }])
    described_class.new(storage_client: storage).run(['own-key'])
    requests = storage.api_requests.select { |request| request[:operation_name] == :delete_objects }
    expect(requests.size).to eq(1)
    expect(requests.first.fetch(:params)).to include(bucket: 'private-files',
                                                     delete: { objects: [{ key: 'own-key', version_id: 'one' },
                                                                         { key: 'own-key', version_id: 'marker' }] })
  end

  it 'fails explicitly so the durable removal receipt can retry file cleanup' do
    storage.stub_responses(:list_object_versions, versions: [{ key: 'own-key', version_id: 'one' }])
    storage.stub_responses(:delete_objects, errors: [{ key: 'own-key', version_id: 'one', code: 'AccessDenied', message: 'denied' }])
    expect do
      described_class.new(storage_client: storage).run(['own-key'])
    end.to raise_error(RuntimeError, 'Attachment cleanup failed')
  end
end
