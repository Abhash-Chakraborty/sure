require "test_helper"

class Account::LinkableTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
  end

  test "linked? returns false when account has no providers" do
    assert @account.unlinked?
  end

  test "supports_category_matcher? returns false for unlinked accounts" do
    refute @account.supports_category_matcher?
  end

  test "can_delete_holdings? returns true for unlinked accounts" do
    assert @account.unlinked?
    assert @account.can_delete_holdings?
  end

  test "linked scope excludes manual accounts" do
    assert @account.unlinked?
    refute_includes Account.linked, @account
  end
end
