require 'aws-sdk-s3'

class Abera::ObjectCleanup
  def initialize(storage_client: Aws::S3::Client.new)
    @s3 = storage_client
  end

  def run(keys)
    bucket = ENV.fetch('S3_BUCKET_NAME')
    keys.each do |key|
      @s3.list_object_versions(bucket: bucket, prefix: key).each_page do |page|
        objects = (page.versions + page.delete_markers).select { |object| object.key == key }
        next if objects.empty?

        response = @s3.delete_objects(bucket: bucket, delete: { objects: objects.map { |object| { key: key, version_id: object.version_id } } })
        raise 'Attachment cleanup failed' if response.errors.any?
      end
    end
  end
end
