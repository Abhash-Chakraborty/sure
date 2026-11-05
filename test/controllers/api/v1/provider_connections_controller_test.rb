# frozen_string_literal: true

require "test_helper"

class Api::V1::ProviderConnectionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family

    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      display_key: "test_read_#{SecureRandom.hex(8)}",
      source: "web"
    )

    @read_write_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Write Key",
      scopes: [ "read_write" ],
      display_key: "test_rw_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    redis = Redis.new
    redis.del("api_rate_limit:#{@api_key.id}")
    redis.del("api_rate_limit:#{@read_write_key.id}")
  end

  test "read_write key can list provider connection status" do
    get api_v1_provider_connections_url, headers: api_headers(@read_write_key)
    assert_response :success
  end

  test "returns an empty list when no provider connections exist" do
    ProviderConnectionStatus.stub(:for_family, []) do
      get api_v1_provider_connections_url, headers: api_headers(@api_key)
    end

    assert_response :success
    assert_equal [], JSON.parse(response.body)["data"]
  end

  test "requires authentication" do
    get api_v1_provider_connections_url
    assert_response :unauthorized
  end

  test "rejects api keys without read scope" do
    write_only_key = ApiKey.new(
      user: @user,
      name: "Test Write Key",
      scopes: [ "write" ],
      display_key: "test_write_#{SecureRandom.hex(8)}",
      source: "monitoring"
    ).tap { |api_key| api_key.save!(validate: false) }

    get api_v1_provider_connections_url, headers: api_headers(write_only_key)
    assert_response :forbidden
  end

  test "does not leak internal provider status errors" do
    ProviderConnectionStatus.stub(:for_family, ->(_family) { raise StandardError, "secret provider failure" }) do
      get api_v1_provider_connections_url, headers: api_headers(@api_key)
    end

    assert_response :internal_server_error
    assert_equal "internal_server_error", JSON.parse(response.body)["error"]
    refute_includes response.body, "secret provider failure"
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end
end
