require "test_helper"
require "ostruct"

class Settings::MailServersControllerTest < ActionDispatch::IntegrationTest
  include ProviderTestHelper

  setup do
    users(:family_admin).update!(role: :super_admin)
    sign_in users(:family_admin)
    clear_mail_server
  end

  teardown { clear_mail_server }

  test "saves the mail server" do
    with_self_hosting do
      with_env_overrides("SMTP_ADDRESS" => nil, "EMAIL_SENDER" => nil) do
        patch settings_mail_server_url, params: { setting: {
          smtp_address: " smtp.example.com ",
          smtp_port: "465",
          smtp_username: "me@example.com",
          smtp_password: "app-password",
          smtp_tls_enabled: "1",
          email_sender: "sure@example.com"
        } }

        assert_redirected_to settings_hosting_url
        assert_equal I18n.t("settings.mail_servers.update.saved"), flash[:notice]
        assert_equal "smtp.example.com", Setting.smtp_address
        assert_equal 465, Setting.smtp_port
        assert_equal "me@example.com", Setting.smtp_username
        assert_equal "app-password", Setting.smtp_password
        assert Setting.smtp_tls_enabled
        assert_equal "sure@example.com", Setting.email_sender
      end
    end
  end

  test "the masked password keeps the stored one and a blank one clears it" do
    Setting.smtp_password = "app-password"

    with_self_hosting do
      with_env_overrides("SMTP_ADDRESS" => nil) do
        patch settings_mail_server_url, params: { setting: { smtp_address: "smtp.example.com", smtp_password: "********" } }
        assert_equal "app-password", Setting.smtp_password

        patch settings_mail_server_url, params: { setting: { smtp_address: "smtp.example.com", smtp_password: "" } }
        assert_nil Setting.smtp_password
      end
    end
  end

  test "rejects a port that isn't one" do
    with_self_hosting do
      with_env_overrides("SMTP_ADDRESS" => nil) do
        patch settings_mail_server_url, params: { setting: { smtp_address: "smtp.example.com", smtp_port: "99999" } }

        assert_redirected_to settings_hosting_url
        assert_equal I18n.t("settings.mail_servers.update.invalid_port"), flash[:alert]
        assert_nil Setting.smtp_address
      end
    end
  end

  test "rejects a sender that isn't an email address" do
    with_self_hosting do
      with_env_overrides("SMTP_ADDRESS" => nil, "EMAIL_SENDER" => nil) do
        patch settings_mail_server_url, params: { setting: { smtp_address: "smtp.example.com", email_sender: "not an address" } }

        assert_equal I18n.t("settings.mail_servers.update.invalid_sender"), flash[:alert]
        assert_nil Setting.email_sender
      end
    end
  end

  test "a family admin can't change it on an instance with several families" do
    with_self_hosting do
      with_env_overrides("SMTP_ADDRESS" => nil) do
        sign_in users(:empty)

        patch settings_mail_server_url, params: { setting: { smtp_address: "attacker.example" } }

        assert_redirected_to settings_hosting_url
        assert_equal I18n.t("settings.mail_servers.not_authorized"), flash[:alert]
        assert_nil Setting.smtp_address
      end
    end
  end

  test "env vars keep the server out of reach" do
    with_self_hosting do
      with_env_overrides("SMTP_ADDRESS" => "env.example.com") do
        patch settings_mail_server_url, params: { setting: { smtp_address: "smtp.example.com" } }

        assert_equal I18n.t("settings.mail_servers.env_managed"), flash[:alert]
        assert_nil Setting.smtp_address
      end
    end
  end

  test "sends a test email to the signed-in user" do
    Setting.smtp_address = "smtp.example.com"

    with_self_hosting do
      with_env_overrides("SMTP_ADDRESS" => nil) do
        assert_emails 1 do
          post send_test_settings_mail_server_url
        end

        assert_redirected_to settings_hosting_url
        assert_equal I18n.t("settings.mail_servers.send_test.sent", email: users(:family_admin).email), flash[:notice]
      end
    end
  end

  test "a test email needs a server" do
    with_self_hosting do
      with_env_overrides("SMTP_ADDRESS" => nil) do
        assert_no_emails do
          post send_test_settings_mail_server_url
        end

        assert_equal I18n.t("settings.mail_servers.send_test.not_configured"), flash[:alert]
      end
    end
  end

  test "the self-hosting page shows the mail server form with the password masked" do
    Setting.smtp_address = "smtp.example.com"
    Setting.smtp_password = "app-password"
    stub_providers

    with_self_hosting do
      with_env_overrides("SMTP_ADDRESS" => nil) do
        get settings_hosting_url

        assert_response :success
        assert_select "input[name='setting[smtp_address]'][value='smtp.example.com']"
        assert_select "input[name='setting[smtp_password]'][value='********']"
        assert_not_includes response.body, "app-password"
      end
    end
  end

  private
    def clear_mail_server
      Setting.smtp_address = nil
      Setting.smtp_port = nil
      Setting.smtp_username = nil
      Setting.smtp_password = nil
      Setting.smtp_tls_enabled = false
      Setting.email_sender = nil
    end

    # The rest of the self-hosting page asks the market data providers for
    # their usage; the same stubs as Settings::HostingsControllerTest.
    def stub_providers
      provider = mock
      provider.stubs(:health_status).returns(:healthy)
      provider.stubs(:usage).returns(provider_success_response(OpenStruct.new(used: 10, limit: 100, utilization: 10, plan: "free")))
      Provider::Registry.stubs(:get_provider).with(:yahoo_finance).returns(provider)
    end
end
