require "test_helper"

class Provider::MetadataTest < ActiveSupport::TestCase
  test "registered provider metadata only uses kinds" do
    Provider::Metadata::REGISTRY.each_value do |metadata|
      assert metadata.key?(:kinds)
      refute metadata.key?(:kind)
    end
  end

  test "registered provider metadata keeps fallback colors out of raw tailwind classes" do
    Provider::Metadata::REGISTRY.each_value do |metadata|
      refute metadata.key?(:logo_bg)
      assert_match(/\A#[0-9a-f]{6}\z/i, metadata[:logo_color]) if metadata[:logo_color].present?
    end
  end

  test "logo_url builds a Brandfetch URL from the provider domain" do
    Setting.stubs(:brand_fetch_client_id).returns("test-client-id")
    Setting.stubs(:brand_fetch_logo_size).returns(40)
    Provider::Metadata.stubs(:for).with(:example).returns({ domain: "example.com" })

    assert_equal "https://cdn.brandfetch.io/example.com/icon/fallback/404/w/40/h/40?c=test-client-id",
                 Provider::Metadata.logo_url(:example)
  end

  test "logo_url is nil when Brandfetch is not configured" do
    Setting.stubs(:brand_fetch_client_id).returns(nil)
    Provider::Metadata.stubs(:for).with(:example).returns({ domain: "example.com" })

    assert_nil Provider::Metadata.logo_url(:example)
  end

  test "logo_url is nil for providers without a domain" do
    Setting.stubs(:brand_fetch_client_id).returns("test-client-id")

    assert_nil Provider::Metadata.logo_url(:unknown_provider)
  end
end
