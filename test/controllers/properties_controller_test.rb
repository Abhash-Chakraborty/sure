require "test_helper"

class PropertiesControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:property)
  end

  test "creates property in draft status and redirects to balances step" do
    assert_difference -> { Account.count } => 1 do
      post properties_path, params: {
        account: {
          name: "New Property",
          subtype: "house",
          currency: "EUR",
          institution_name: "Property Lender",
          institution_domain: "propertylender.example",
          notes: "Property notes",
          accountable_type: "Property",
          accountable_attributes: {
            year_built: 1990,
            area_value: 1200,
            area_unit: "sqft"
          }
        }
      }
    end

    created_account = Account.order(:created_at).last
    assert created_account.accountable.is_a?(Property)
    assert_equal "draft", created_account.status
    assert_equal 0, created_account.balance
    assert_equal "EUR", created_account.currency
    assert_equal "Property Lender", created_account[:institution_name]
    assert_equal "propertylender.example", created_account[:institution_domain]
    assert_equal "Property notes", created_account[:notes]
    assert_equal 1990, created_account.accountable.year_built
    assert_equal 1200, created_account.accountable.area_value
    assert_equal "sqft", created_account.accountable.area_unit
    assert created_account.accountable.user_set_area?, "a manually entered area should count as user-set"
    assert_redirected_to balances_property_path(created_account)
  end

  test "updates property overview" do
    assert_no_difference [ "Account.count", "Property.count" ] do
      patch property_path(@account), params: {
        account: {
          name: "Updated Property",
          institution_name: "Updated Lender",
          institution_domain: "updatedlender.example",
          notes: "Updated property notes",
          accountable_attributes: {
            id: @account.accountable.id,
            subtype: "condominium"
          }
        }
      }
    end

    @account.reload
    assert_equal "Updated Property", @account.name
    assert_equal "condominium", @account.subtype
    assert_equal "Updated Lender", @account[:institution_name]
    assert_equal "updatedlender.example", @account[:institution_domain]
    assert_equal "Updated property notes", @account[:notes]

    # If account is active, it renders edit view; otherwise redirects to balances
    if @account.active?
      assert_response :success
    else
      assert_redirected_to balances_property_path(@account)
    end
  end

  test "editing the living area marks it as user-set, so valuation refreshes send it" do
    property = @account.accountable
    assert_not property.user_set_area?

    patch property_path(@account), params: {
      account: { accountable_attributes: { id: property.id, area_value: 1364, area_unit: "sqft" } }
    }

    property.reload
    assert_equal 1364, property.area_value
    assert property.locked?(:area_value)
    assert property.user_set_area?
  end

  # Tab view tests
  test "shows balances tab" do
    get balances_property_path(@account)
    assert_response :success
  end

  test "shows address tab" do
    get address_property_path(@account)
    assert_response :success
  end

  # Tab update tests
  test "updates balances tab" do
    original_balance = @account.balance

    patch update_balances_property_path(@account), params: {
      account: {
        balance: 600000,
        currency: "EUR"
      }
    }

    @account.reload
    assert_equal 600000, @account.balance
    assert_equal "EUR", @account.currency

    # If account is active, it renders balances view; otherwise redirects to address
    if @account.active?
      assert_response :success
    else
      assert_redirected_to address_property_path(@account)
    end
  end

  test "updates address tab" do
    patch update_address_property_path(@account), params: {
      property: {
        address_attributes: {
          line1: "456 New Street",
          locality: "San Francisco",
          region: "CA",
          country: "US",
          postal_code: "94102"
        }
      }
    }

    @account.reload
    assert_equal "456 New Street", @account.accountable.address.line1
    assert_equal "San Francisco", @account.accountable.address.locality

    # If account is draft, it activates and redirects; otherwise renders address
    if @account.draft?
      assert_redirected_to account_path(@account)
    else
      assert_response :success
    end
  end

  test "balances update handles validation errors" do
    Account.any_instance.stubs(:set_current_balance).returns(OpenStruct.new(success?: false, error_message: "Invalid balance"))

    patch update_balances_property_path(@account), params: {
      account: {
        balance: 600000,
        currency: "EUR"
      }
    }

    assert_response :unprocessable_entity
  end

  test "address update handles validation errors" do
    Property.any_instance.stubs(:update).returns(false)

    patch update_address_property_path(@account), params: {
      property: {
        address_attributes: {
          line1: "123 Test St"
        }
      }
    }

    assert_response :unprocessable_entity
  end

  test "address update activates draft account" do
    # Create a draft property account
    draft_account = Account.create!(
      family: @user.family,
      name: "Draft Property",
      accountable: Property.new,
      status: "draft",
      balance: 500000,
      currency: "USD"
    )

    assert draft_account.draft?

    patch update_address_property_path(draft_account), params: {
      property: {
        address_attributes: {
          line1: "789 Activate St",
          locality: "New York",
          region: "NY",
          country: "US",
          postal_code: "10001"
        }
      }
    }

    draft_account.reload
    assert draft_account.active?
    assert_redirected_to account_path(draft_account)
  end

  test "address update on draft account honors stored return_to over the account page" do
    draft_account = Account.create!(
      family: @user.family,
      name: "Draft Property RT",
      accountable: Property.new,
      status: "draft",
      balance: 500000,
      currency: "USD"
    )

    # The property wizard (create → balances → address) doesn't thread return_to
    # as a form param, so StoreLocation's session value is the only carrier.
    get new_account_path(return_to: transactions_path)

    patch update_address_property_path(draft_account), params: {
      property: {
        address_attributes: {
          line1: "789 Activate St",
          locality: "New York",
          region: "NY",
          country: "US",
          postal_code: "10001"
        }
      }
    }

    draft_account.reload
    assert draft_account.active?
    assert_redirected_to transactions_path
  end

  test "address update ignores an external stored return_to (open-redirect guard)" do
    draft_account = Account.create!(
      family: @user.family,
      name: "Draft Property Evil",
      accountable: Property.new,
      status: "draft",
      balance: 500000,
      currency: "USD"
    )

    # A hostile ?return_to is rejected at store time, so the wizard falls back
    # to the account page rather than stream-redirecting off-site.
    get new_account_path(return_to: "https://evil.example/phish")

    patch update_address_property_path(draft_account), params: {
      property: {
        address_attributes: {
          line1: "1 Safe St", locality: "NYC", region: "NY", country: "US", postal_code: "10001"
        }
      }
    }

    draft_account.reload
    assert draft_account.active?
    assert_redirected_to account_path(draft_account)
  end

  test "address update tolerates a non-String stored return_to without raising" do
    draft_account = Account.create!(
      family: @user.family,
      name: "Draft Property Array",
      accountable: Property.new,
      status: "draft",
      balance: 500000,
      currency: "USD"
    )

    # `?return_to[]=foo` makes params[:return_to] an Array; safe_return_to must
    # reject it via the is_a?(String) guard instead of raising NoMethodError.
    get new_account_path("return_to" => [ "/transactions" ])

    patch update_address_property_path(draft_account), params: {
      property: {
        address_attributes: {
          line1: "1 Safe St", locality: "NYC", region: "NY", country: "US", postal_code: "10001"
        }
      }
    }

    draft_account.reload
    assert draft_account.active?
    assert_redirected_to account_path(draft_account)
  end

  test "new skips method selector when no AVM provider is configured" do
    get new_property_path(step: "method_select")

    assert_response :success
    assert_match "Enter property manually", response.body
  end

  test "rejects AVM creation for unconfigured providers" do
    assert_no_difference "Account.count" do
      post properties_path, params: {
        avm_provider: "realie",
        account: {
          name: "AVM Home",
          accountable_type: "Property",
          address: { line1: "123 Main Street", locality: "LA", region: "CA", postal_code: "90001" }
        }
      }
    end

    assert_redirected_to new_property_path
  end

  test "edit form leaves out the icon picker, which property updates do not save" do
    get edit_property_url(@account)

    assert_response :success
    assert_select "[data-controller=account-logo-picker]", 0
    assert_select "form##{dom_id(@account, :logo_options)}", 0
  end

  test "refresh_valuation does nothing for properties without a provider" do
    @account.property.update!(avm_provider: nil)

    assert_no_enqueued_jobs(only: SyncPropertyValuationsJob) do
      post refresh_valuation_property_path(@account)
    end

    assert_redirected_to account_path(@account)
  end

  test "refresh_valuation refuses when the provider is no longer configured" do
    @account.property.update!(avm_provider: "chimnie", avm_external_id: "999000000001")

    assert_no_enqueued_jobs(only: SyncPropertyValuationsJob) do
      post refresh_valuation_property_path(@account)
    end

    assert_redirected_to account_path(@account)
    assert flash[:alert].present?
  end

  test "refresh_valuation is scoped to the current family" do
    @account.property.update!(avm_provider: "chimnie", avm_external_id: "999000000001")
    sign_in users(:empty)

    assert_no_enqueued_jobs(only: SyncPropertyValuationsJob) do
      post refresh_valuation_property_path(@account)
    end

    assert_response :not_found
  end

  test "overview offers a valuation refresh for provider-linked properties" do
    @account.property.update!(avm_provider: "chimnie", avm_external_id: "999000000001", avm_last_synced_on: Date.current)

    get account_path(@account, tab: "overview")

    assert_response :success
    assert_select "form[action='#{refresh_valuation_property_path(@account)}']"
  end

  test "link_valuation refuses an unconfigured provider" do
    @account.property.update!(avm_provider: nil)

    assert_no_enqueued_jobs(only: SyncPropertyValuationsJob) do
      post link_valuation_property_path(@account, avm_provider: "rentcast")
    end

    assert_redirected_to account_path(@account)
    assert_nil @account.property.reload.avm_provider
  end

  test "link_valuation is scoped to the current family" do
    @account.property.update!(avm_provider: nil)
    sign_in users(:empty)

    assert_no_enqueued_jobs(only: SyncPropertyValuationsJob) do
      post link_valuation_property_path(@account, avm_provider: "rentcast")
    end

    assert_response :not_found
    assert_nil @account.property.reload.avm_provider
  end
end
