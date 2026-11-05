require "test_helper"

class Settings::ProvidersControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  # No configurable sync provider ships any more. These stand-ins register
  # instance-wide credentials the way the removed Plaid adapters did (fields
  # stored as dynamic settings), so the generic form and update action stay
  # covered. They register in setup and are removed again in teardown.
  class ExampleBankAdapter
    include Provider::Configurable

    def self.register_configuration
      configure do
        description "Example bank provider"
        field :client_id, label: "Client ID", required: true
        field :secret, label: "Secret", required: true, secret: true
        field :environment, label: "Environment", default: "sandbox"
      end
    end
  end

  class ExampleEuAdapter
    include Provider::Configurable

    def self.register_configuration
      configure do
        description "Example EU bank provider"
        field :client_id, label: "Client ID", required: true
        field :secret, label: "Secret", required: true, secret: true
      end
    end
  end

  STAND_IN_ADAPTERS = [ ExampleBankAdapter, ExampleEuAdapter ].freeze

  setup do
    # Exercise controller jobs independently of the daily login sync.
    families(:dylan_family).update!(auto_sync_on_login: false)
    ensure_tailwind_build
    # Provider credentials are instance-wide, so saving them takes a super
    # admin. Promote the fixture admin rather than switching users so the
    # family-scoped assertions below keep using dylan_family.
    users(:family_admin).update!(role: :super_admin)
    sign_in users(:family_admin)

    # Ensure provider adapters are loaded for all tests
    Provider::Factory.ensure_adapters_loaded
    STAND_IN_ADAPTERS.each(&:register_configuration)
  end

  teardown do
    STAND_IN_ADAPTERS.each do |adapter|
      Provider::ConfigurationRegistry.send(:registry).delete(adapter.provider_key)
      Provider::ConfigurationRegistry.send(:adapter_registry).delete(adapter.provider_key)
    end
  end

  test "GET /settings/bank_sync redirects permanently to /settings/providers" do
    get "/settings/bank_sync"
    assert_redirected_to "/settings/providers"
    assert_equal 301, response.status
  end

  test "can access when self hosting is disabled (managed mode)" do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    get settings_providers_url
    assert_response :success

    patch settings_providers_url, params: { setting: { example_bank_client_id: "test123" } }
    assert_redirected_to settings_providers_url
  end

  test "a family admin cannot change instance-wide provider credentials in managed mode" do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    sign_in users(:empty)

    patch settings_providers_url, params: { setting: { example_bank_client_id: "attacker", example_bank_secret: "attacker-secret" } }

    assert_redirected_to settings_providers_url
    assert_equal I18n.t("settings.providers.not_authorized"), flash[:alert]
    assert_nil Setting["example_bank_client_id"]
    assert_nil Setting["example_bank_secret"]
  end

  test "a family admin cannot change provider credentials on a self-hosted instance with several families" do
    with_self_hosting do
      sign_in users(:empty)

      patch settings_providers_url, params: { setting: { example_bank_client_id: "attacker" } }

      assert_redirected_to settings_providers_url
      assert_nil Setting["example_bank_client_id"]
    end
  end

  test "the admin of the only family on a self-hosted instance can change provider credentials" do
    with_self_hosting do
      Family.stubs(:count).returns(1)
      sign_in users(:empty)

      patch settings_providers_url, params: { setting: { example_bank_client_id: "own-client-id" } }

      assert_redirected_to settings_providers_url
      assert_equal "own-client-id", Setting["example_bank_client_id"]
    end
  ensure
    Setting["example_bank_client_id"] = nil
  end

  test "instance-wide provider forms are only offered to those who may save them" do
    instance_wide_forms = Provider::ConfigurationRegistry.all.map do |config|
      connect_form_settings_providers_path(provider_key: config.provider_key)
    end

    get settings_providers_url
    assert instance_wide_forms.any? { |path| response.body.include?(path) }

    sign_in users(:empty)

    get settings_providers_url
    assert_response :success
    assert instance_wide_forms.none? { |path| response.body.include?(path) }

    get connect_form_settings_providers_path(provider_key: "example_bank")
    assert_redirected_to settings_providers_path
    assert_equal I18n.t("settings.providers.not_authorized"), flash[:alert]
  end

  test "should get show when self hosting is enabled" do
    with_self_hosting do
      get settings_providers_url
      assert_response :success
    end
  end

  # The provider card reads its tagline with `default: nil`, so a missing key
  # renders a bare name rather than failing. Up shipped that way.
  test "every family panel provider has an English tagline" do
    missing = Settings::ProvidersController::FAMILY_PANEL_KEYS.reject do |key|
      I18n.exists?("settings.providers.taglines.#{key}", :en)
    end

    assert_empty missing
  end

  test "sync all control submits with POST" do
    # A configured provider is a connection, which offers Sync all.
    Setting["example_bank_client_id"] = "client-id"
    Setting["example_bank_secret"] = "secret"

    with_self_hosting do
      get settings_providers_url
      assert_response :success
      assert_select "form[action=?][method=?]", sync_all_settings_providers_path, "post"
    end
  ensure
    Setting["example_bank_client_id"] = nil
    Setting["example_bank_secret"] = nil
  end

  test "correctly identifies declared vs dynamic fields" do
    # All current provider fields are dynamic, but the logic should correctly
    # distinguish between declared and dynamic fields
    with_self_hosting do
      # example_bank_client_id is a dynamic field (not defined in Setting)
      refute Setting.singleton_class.method_defined?(:example_bank_client_id=),
        "example_bank_client_id= should NOT be defined on Setting's singleton class"

      # openai_model IS a declared field (defined in Setting)
      # but it's not a provider field, so it won't go through this controller
      assert Setting.singleton_class.method_defined?(:openai_model=),
        "openai_model= should be defined on Setting's singleton class"
    end
  end

  test "updates dynamic provider fields using batch update" do
    # example_bank_client_id is a dynamic field, stored as an individual entry
    with_self_hosting do
      # Clear any existing example_bank settings
      Setting["example_bank_client_id"] = nil

      patch settings_providers_url, params: {
        setting: { example_bank_client_id: "test_client_id" }
      }

      assert_redirected_to settings_providers_url
      assert_equal "test_client_id", Setting["example_bank_client_id"]
    end
  end

  test "batches multiple dynamic fields from same provider atomically" do
    # Test that multiple fields from one provider are updated as individual entries
    with_self_hosting do
      # Clear existing fields
      Setting["example_bank_client_id"] = nil
      Setting["example_bank_secret"] = nil
      Setting["example_bank_environment"] = nil

      patch settings_providers_url, params: {
        setting: {
          example_bank_client_id: "new_client_id",
          example_bank_secret: "new_secret",
          example_bank_environment: "production"
        }
      }

      assert_redirected_to settings_providers_url

      # All three should be present as individual entries
      assert_equal "new_client_id", Setting["example_bank_client_id"]
      assert_equal "new_secret", Setting["example_bank_secret"]
      assert_equal "production", Setting["example_bank_environment"]
    end
  end

  test "batches dynamic fields from multiple providers atomically" do
    # Test that fields from different providers are stored as individual entries
    with_self_hosting do
      # Clear existing fields
      Setting["example_bank_client_id"] = nil
      Setting["example_bank_secret"] = nil
      Setting["example_eu_client_id"] = nil
      Setting["example_eu_secret"] = nil

      patch settings_providers_url, params: {
        setting: {
          example_bank_client_id: "plaid_client",
          example_bank_secret: "example_bank_secret",
          example_eu_client_id: "plaid_eu_client",
          example_eu_secret: "example_eu_secret"
        }
      }

      assert_redirected_to settings_providers_url

      # All fields should be present
      assert_equal "plaid_client", Setting["example_bank_client_id"]
      assert_equal "example_bank_secret", Setting["example_bank_secret"]
      assert_equal "plaid_eu_client", Setting["example_eu_client_id"]
      assert_equal "example_eu_secret", Setting["example_eu_secret"]
    end
  end

  test "preserves existing dynamic fields when updating new ones" do
    # Test that updating some fields doesn't overwrite other existing fields
    with_self_hosting do
      # Set initial fields
      Setting["existing_field_1"] = "value1"
      Setting["example_bank_client_id"] = "old_client_id"

      # Update one field and add a new one
      patch settings_providers_url, params: {
        setting: {
          example_bank_client_id: "new_client_id",
          example_bank_secret: "new_secret"
        }
      }

      assert_redirected_to settings_providers_url

      # Existing unrelated field should still be there
      assert_equal "value1", Setting["existing_field_1"]

      # Updated field should have new value
      assert_equal "new_client_id", Setting["example_bank_client_id"]

      # New field should be added
      assert_equal "new_secret", Setting["example_bank_secret"]
    end
  end

  test "skips placeholder values for secret fields" do
    with_self_hosting do
      # Set an initial secret value
      Setting["example_bank_secret"] = "real_secret"

      # Try to update with placeholder
      patch settings_providers_url, params: {
        setting: {
          example_bank_client_id: "new_client_id",
          example_bank_secret: "********"  # Placeholder value
        }
      }

      assert_redirected_to settings_providers_url

      # Client ID should be updated
      assert_equal "new_client_id", Setting["example_bank_client_id"]

      # Secret should remain unchanged
      assert_equal "real_secret", Setting["example_bank_secret"]
    end
  end

  test "converts blank values to nil and removes from dynamic_fields" do
    with_self_hosting do
      # Set initial values
      Setting["example_bank_client_id"] = "old_value"
      assert_equal "old_value", Setting["example_bank_client_id"]
      assert Setting.key?("example_bank_client_id")

      patch settings_providers_url, params: {
        setting: { example_bank_client_id: "  " }  # Blank string with spaces
      }

      assert_redirected_to settings_providers_url
      assert_nil Setting["example_bank_client_id"]
      # Entry should be removed, not just set to nil
      refute Setting.key?("example_bank_client_id"),
        "nil values should delete the entry"
    end
  end

  test "handles sequential updates to different dynamic fields safely" do
    # This test simulates what would happen if two requests tried to update
    # different dynamic fields sequentially. With individual entries,
    # all changes should be preserved without conflicts.
    with_self_hosting do
      Setting["existing_field"] = "existing_value"

      # Simulate first request updating example_bank fields
      patch settings_providers_url, params: {
        setting: {
          example_bank_client_id: "client_id_1",
          example_bank_secret: "secret_1"
        }
      }

      # Existing field should still be there
      assert_equal "existing_value", Setting["existing_field"]

      # New fields should be added
      assert_equal "client_id_1", Setting["example_bank_client_id"]
      assert_equal "secret_1", Setting["example_bank_secret"]

      # Simulate second request updating different example_bank fields
      patch settings_providers_url, params: {
        setting: {
          example_bank_environment: "production"
        }
      }

      # All previously set fields should still be there
      assert_equal "existing_value", Setting["existing_field"]
      assert_equal "client_id_1", Setting["example_bank_client_id"]
      assert_equal "secret_1", Setting["example_bank_secret"]
      assert_equal "production", Setting["example_bank_environment"]
    end
  end

  test "only processes valid configuration fields" do
    with_self_hosting do
      # Try to update a field that doesn't exist in any provider configuration
      patch settings_providers_url, params: {
        setting: {
          example_bank_client_id: "valid_field",
          fake_field_that_does_not_exist: "should_be_ignored"
        }
      }

      assert_redirected_to settings_providers_url

      # Valid field should be updated
      assert_equal "valid_field", Setting["example_bank_client_id"]

      # Invalid field should not be stored
      assert_nil Setting["fake_field_that_does_not_exist"]
    end
  end

  test "calls reload_configuration on updated providers" do
    with_self_hosting do
      # Mock the adapter class to verify reload_configuration is called
      ExampleBankAdapter.expects(:reload_configuration).once

      patch settings_providers_url, params: {
        setting: { example_bank_client_id: "new_client_id" }
      }

      assert_redirected_to settings_providers_url
    end
  end

  test "reloads configuration for multiple providers when updated" do
    with_self_hosting do
      # Both providers should have their configuration reloaded
      ExampleBankAdapter.expects(:reload_configuration).once
      ExampleEuAdapter.expects(:reload_configuration).once

      patch settings_providers_url, params: {
        setting: {
          example_bank_client_id: "plaid_client",
          example_eu_client_id: "plaid_eu_client"
        }
      }

      assert_redirected_to settings_providers_url
    end
  end

  test "logs errors when update fails" do
    with_self_hosting do
      # Test that errors during update are properly logged and handled gracefully
      # We'll force an error by making the []= method raise
      Setting.expects(:[]=).with("example_bank_client_id", "test").raises(StandardError.new("Database error")).once

      # Mock logger to verify error is logged (pin both the exception class
      # name and the message so a regression that drops one still fails).
      Rails.logger.expects(:error).with(regexp_matches(/Failed to update provider settings: StandardError - Database error/)).once

      patch settings_providers_url, params: {
        setting: { example_bank_client_id: "test" }
      }

      # Controller should handle the error gracefully with generic message (no internal details)
      assert_response :unprocessable_entity
      assert_equal "Failed to update provider settings. Please try again.", flash[:alert]
    end
  end

  test "shows no changes message when no fields are updated" do
    with_self_hosting do
      # Only send a secret field with placeholder value (which gets skipped)
      Setting["example_bank_secret"] = "existing_secret"

      patch settings_providers_url, params: {
        setting: { example_bank_secret: "********" }
      }

      assert_redirected_to settings_providers_url
      assert_equal "No changes were made", flash[:notice]
    end
  end

  test "POST sync_all enqueues SyncAllProvidersJob" do
    families(:dylan_family).update_column(:last_sync_all_attempted_at, nil)

    assert_enqueued_with(job: SyncAllProvidersJob) do
      post sync_all_settings_providers_path
    end

    assert_redirected_to settings_providers_path

    follow_redirect!
    assert_response :success
    assert_match(/Syncing all connected providers/i, response.body)
  end

  test "POST sync_all respects recent sync throttle" do
    families(:dylan_family).update_column(:last_sync_all_attempted_at, Time.current)

    assert_no_enqueued_jobs only: SyncAllProvidersJob do
      post sync_all_settings_providers_path
    end

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("settings.providers.sync_all_recently"), flash[:notice]
  end

  test "GET show warns on configured provider forms when self-hosted encryption keys are not explicitly configured" do
    Setting["example_bank_client_id"] = "test-client-id"
    Setting["example_bank_secret"] = "test-secret"
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(false)

    with_self_hosting do
      get settings_providers_url

      assert_response :success
      assert_includes response.body, I18n.t("settings.providers.provider_setup_encryption_warning.title")
      assert_select 'a[href=?][target="_blank"][rel="noopener noreferrer"]',
                    "https://github.com/we-promise/docs/blob/main/self-hosting.mdx#turning-on-active-record-encryption-after-first-boot",
                    minimum: 1
      assert_includes response.body, I18n.t("settings.providers.provider_setup_encryption_warning.message")
      assert_includes response.body, I18n.t("settings.providers.drawer_trust_statement_encryption_unconfigured")
    end
  ensure
    Setting["example_bank_client_id"] = nil
    Setting["example_bank_secret"] = nil
  end

  test "GET show hides provider form encryption warning in managed mode" do
    Setting["example_bank_client_id"] = "test-client-id"
    Setting["example_bank_secret"] = "test-secret"
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(false)

    get settings_providers_url

    assert_response :success
    refute_includes response.body, I18n.t("settings.providers.provider_setup_encryption_warning.title")
    assert_select 'a[href=?][target="_blank"][rel="noopener noreferrer"]',
                  "https://github.com/we-promise/docs/blob/main/self-hosting.mdx#turning-on-active-record-encryption-after-first-boot",
                  count: 0
    refute_includes response.body, I18n.t("settings.providers.provider_setup_encryption_warning.message")
    refute_includes response.body, I18n.t("settings.providers.drawer_trust_statement_encryption_unconfigured")
  ensure
    Setting["example_bank_client_id"] = nil
    Setting["example_bank_secret"] = nil
  end

  test "GET connect_form warns when self-hosted encryption keys are not explicitly configured" do
    with_self_hosting do
      ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(false)

      get connect_form_settings_providers_path(provider_key: "example_bank")

      assert_response :success
      assert_includes response.body, I18n.t("settings.providers.provider_setup_encryption_warning.title")
      assert_select 'a[href=?][target="_blank"][rel="noopener noreferrer"]',
                    "https://github.com/we-promise/docs/blob/main/self-hosting.mdx#turning-on-active-record-encryption-after-first-boot",
                    minimum: 1
      assert_includes response.body, I18n.t("settings.providers.provider_setup_encryption_warning.message")
      assert_includes response.body, I18n.t("settings.providers.drawer_trust_statement_encryption_unconfigured")
      refute_includes response.body, I18n.t("settings.providers.drawer_trust_statement")
    end
  end

  test "GET connect_form hides encryption warning when self-hosted encryption keys are configured" do
    with_self_hosting do
      ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)

      get connect_form_settings_providers_path(provider_key: "example_bank")

      assert_response :success
      refute_includes response.body, I18n.t("settings.providers.provider_setup_encryption_warning.title")
      assert_select 'a[href=?][target="_blank"][rel="noopener noreferrer"]',
                    "https://github.com/we-promise/docs/blob/main/self-hosting.mdx#turning-on-active-record-encryption-after-first-boot",
                    count: 0
      refute_includes response.body, I18n.t("settings.providers.provider_setup_encryption_warning.message")
      assert_includes response.body, I18n.t("settings.providers.drawer_trust_statement")
      refute_includes response.body, I18n.t("settings.providers.drawer_trust_statement_encryption_unconfigured")
    end
  end

  test "GET connect_form hides encryption warning in managed mode" do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(false)

    get connect_form_settings_providers_path(provider_key: "example_bank")

    assert_response :success
    refute_includes response.body, I18n.t("settings.providers.provider_setup_encryption_warning.title")
    assert_select 'a[href=?][target="_blank"][rel="noopener noreferrer"]',
                  "https://github.com/we-promise/docs/blob/main/self-hosting.mdx#turning-on-active-record-encryption-after-first-boot",
                  count: 0
    refute_includes response.body, I18n.t("settings.providers.provider_setup_encryption_warning.message")
    assert_includes response.body, I18n.t("settings.providers.drawer_trust_statement")
    refute_includes response.body, I18n.t("settings.providers.drawer_trust_statement_encryption_unconfigured")
  end

  test "non-admin users cannot update providers" do
    with_self_hosting do
      sign_in users(:family_member)

      patch settings_providers_url, params: {
        setting: { example_bank_client_id: "test" }
      }

      assert_redirected_to root_path
      assert_equal "Not authorized", flash[:alert]

      # Value should not have changed
      assert_nil Setting["example_bank_client_id"]
    end
  end

  test "uses singleton_class method_defined to detect declared fields" do
    with_self_hosting do
      # This test verifies the difference between respond_to? and singleton_class.method_defined?

      # openai_model is a declared field
      assert Setting.singleton_class.method_defined?(:openai_model=),
        "openai_model= should be defined on Setting's singleton class"
      assert Setting.respond_to?(:openai_model=),
        "respond_to? should return true for declared field"

      # example_bank_client_id is a dynamic field
      refute Setting.singleton_class.method_defined?(:example_bank_client_id=),
        "example_bank_client_id= should NOT be defined on Setting's singleton class"
      refute Setting.respond_to?(:example_bank_client_id=),
        "respond_to? should return false for dynamic field"

      # Both methods currently return the same result, but singleton_class.method_defined?
      # is more explicit and reliable for checking if a method is actually defined
    end
  end
end
