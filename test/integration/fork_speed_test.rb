require "test_helper"

class ForkSpeedTest < ActionDispatch::IntegrationTest
  test "pages are compressed for browsers that accept gzip" do
    get new_session_path, headers: { "Accept-Encoding" => "gzip" }

    assert_response :ok
    assert_equal "gzip", response.headers["content-encoding"]
    assert_includes ActiveSupport::Gzip.decompress(response.body), "</html>"
  end

  test "pages are sent as they are to clients that do not ask for gzip" do
    get new_session_path

    assert_response :ok
    assert_nil response.headers["content-encoding"]
    assert_includes response.body, "</html>"
  end

  test "fingerprinted assets may be kept for a year" do
    status, headers, = asset_caching(200).call("PATH_INFO" => "/assets/application-1a2b3c4d.js")

    assert_equal 200, status
    assert_equal "public, max-age=31536000, immutable", headers["cache-control"]
  end

  test "pages and missing assets keep their own cache rules" do
    _, page_headers, = asset_caching(200, "cache-control" => "private").call("PATH_INFO" => "/accounts")
    _, missing_headers, = asset_caching(404).call("PATH_INFO" => "/assets/gone-1a2b3c4d.js")

    assert_equal "private", page_headers["cache-control"]
    assert_nil missing_headers["cache-control"]
  end

  private
    def asset_caching(status, headers = {})
      ForkAssetCaching.new(->(_env) { [ status, headers.dup, [] ] })
    end
end
