require "application_system_test_case"

class Settings::ProvidersTest < ApplicationSystemTestCase
  # No sync provider ships any more. These stand-ins register instance-wide
  # credentials the way the removed configurable providers did, so the page's
  # grouping, card grid, filters and connect drawer stay covered. They register
  # in setup and are removed again in teardown.
  class ExampleBankAdapter
    include Provider::Configurable

    def self.register_configuration
      configure do
        description "Example bank provider"
        field :client_id, label: "Client ID", required: true
        field :secret, label: "Secret", required: true, secret: true
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
    @user = users(:family_admin)
    # Registry-driven provider forms edit instance-wide credentials and are
    # only shown to a super admin.
    @user.update!(role: :super_admin)
    @family = families(:dylan_family)
    STAND_IN_ADAPTERS.each(&:register_configuration)
    login_as @user
  end

  teardown do
    STAND_IN_ADAPTERS.each do |adapter|
      Provider::ConfigurationRegistry.send(:registry).delete(adapter.provider_key)
      Provider::ConfigurationRegistry.send(:adapter_registry).delete(adapter.provider_key)
    end
    Setting["example_bank_client_id"] = nil
    Setting["example_bank_secret"] = nil
    Setting["example_eu_client_id"] = nil
    Setting["example_eu_secret"] = nil
  end

  test "an unconfigured provider appears in Available with a connect affordance" do
    visit settings_providers_path

    assert_no_selector "details", text: "Example Bank"

    within available_provider_cards_container do
      assert_text "Example Bank"
      assert_selector "a[data-turbo-frame='drawer']", text: "Connect"
    end
  end

  test "groups providers into Your connections and Available with counts" do
    configure_example_bank

    visit settings_providers_path

    connections_heading = find(:xpath, "//h2[contains(translate(., 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'your connections')]")
    normalized = connections_heading.text.squish
    assert_match(/Your connections .*· \d+/i, normalized)

    connections_y = connections_heading.native.location.y
    available_heading = find(:xpath, "//h2[contains(translate(., 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'available')]")
    available_y = available_heading.native.location.y
    connection_y = find("details", text: "Example Bank").native.location.y

    assert_operator connections_y, :<, connection_y, "Your connections heading should appear above the connection"
    assert_operator connection_y, :<, available_y, "The connection should appear above Available heading"

    available_grid_top = available_provider_cards_container.native.location.y
    assert_operator available_y, :<, available_grid_top, "Available heading should appear above the card grid"
  end

  test "action needed group is absent when no providers have issues" do
    configure_example_bank

    visit settings_providers_path

    assert_selector "h2", text: /\AYour connections/i
    assert_no_selector "h2", text: /\AAction needed/i
  end

  test "search input filters provider cards by name" do
    visit settings_providers_path

    find('[data-providers-filter-target="input"]').set("Example Eu")

    assert_selector "a[data-providers-filter-target='card']", text: /Example Eu/i
    assert_no_selector "a[data-providers-filter-target='card']", text: /Example Bank/i
  end

  test "search shows the empty filter message when no provider matches" do
    visit settings_providers_path

    find('[data-providers-filter-target="input"]').set("zzz_no_match_zzz")

    assert_selector '[data-providers-filter-target="empty"]', text: I18n.t("settings.providers.empty_filter")
    assert_no_selector "a[data-providers-filter-target='card']", visible: true
  end

  test "available providers render as a card grid" do
    visit settings_providers_path

    within available_provider_cards_container do
      assert_text "Example Bank"
      assert_selector "a[data-turbo-frame='drawer']", minimum: 1
    end
  end

  test "clicking a provider card opens the connect drawer" do
    visit settings_providers_path

    within available_provider_cards_container do
      find("a[data-turbo-frame='drawer']", text: "Example Bank").click
    end

    assert_selector "dialog[open]"
    assert_text "Client ID"
  end

  test "a configured provider surfaces in Your connections instead of Available" do
    Setting["example_eu_client_id"] = "test_eu_client"
    Setting["example_eu_secret"] = "test_eu_secret"

    visit settings_providers_path

    assert_selector "details summary h3", text: "Example Eu"
    within available_provider_cards_container do
      assert_no_text "Example Eu"
    end
  end

  test "clear filters button resets search input and chip state" do
    visit settings_providers_path

    find('[data-providers-filter-target="input"]').set("zzz_no_match_zzz")
    assert_selector '[data-providers-filter-target="empty"]', visible: true

    click_on I18n.t("settings.providers.clear_filter")

    assert_no_selector '[data-providers-filter-target="empty"]', visible: true
    assert_equal "", find('[data-providers-filter-target="input"]').value
    assert_selector "a[data-providers-filter-target='card']", text: /Example Bank/i
  end

  private

    def configure_example_bank
      Setting["example_bank_client_id"] = "test_client"
      Setting["example_bank_secret"] = "test_secret"
    end

    # Card grid rendered after the `#available` group heading (following sibling div.grid)
    def available_provider_cards_container
      find("#available").find(:xpath, "following-sibling::div[contains(concat(' ', normalize-space(@class), ' '), ' grid ')]")
    end
end
