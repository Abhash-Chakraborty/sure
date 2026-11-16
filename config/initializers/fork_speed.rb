# This Sure is served straight from Puma, with no web server in front of it to
# compress responses or to tell browsers which files they can keep. Without
# these two, a phone downloads about 1.9 MB for its first page and asks for
# each of the 200 script files again on later visits.

# Lets browsers keep fingerprinted assets for a year. Their file names change
# whenever their contents do, so a kept copy is never out of date.
class ForkAssetCaching
  CACHE_CONTROL = "public, max-age=31536000, immutable".freeze
  COMPRESSED_TYPES = %w[
    text/html text/css text/javascript text/plain text/csv text/vnd.turbo-stream.html
    application/javascript application/json application/manifest+json image/svg+xml
  ].freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    status, headers, body = @app.call(env)
    headers["cache-control"] = CACHE_CONTROL if status == 200 && env["PATH_INFO"].to_s.start_with?("/assets/")
    [ status, headers, body ]
  end
end

Rails.application.config.middleware.insert_before 0, Rack::Deflater, include: ForkAssetCaching::COMPRESSED_TYPES
Rails.application.config.middleware.insert_after Rack::Deflater, ForkAssetCaching
