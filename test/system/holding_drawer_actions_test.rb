require "application_system_test_case"

class HoldingDrawerActionsTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(show_sidebar: false, show_ai_sidebar: false)

    @holding = holdings(:one)
  end

  test "unlocking a cost basis asks first and keeps the lock when cancelled" do
    @holding.update!(cost_basis: 12.5, cost_basis_source: "manual", cost_basis_locked: true)

    visit holding_path(@holding)
    click_on I18n.t("holdings.show.unlock_cost_basis")

    within "#confirm-dialog" do
      assert_text I18n.t("holdings.show.unlock_confirm_title")
      assert_selector "button[value=confirm]", text: I18n.t("shared.custom_confirm.default_btn_text")
      find("button[value=cancel]").click
    end

    assert_no_selector "#confirm-dialog[open]"
    assert @holding.reload.cost_basis_locked?

    click_on I18n.t("holdings.show.unlock_cost_basis")
    within("#confirm-dialog") { find("button[value=confirm]").click }

    assert_current_path account_path(@holding.account, tab: "holdings")
    assert_not @holding.reload.cost_basis_locked?
  end
end
