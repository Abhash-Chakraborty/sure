require "test_helper"

class PendingDuplicateMergesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "new redirects if transaction is not pending" do
    posted_transaction = create_transaction(amount: -50, account: @account)

    get new_transaction_pending_duplicate_merges_path(posted_transaction)

    assert_redirected_to transactions_path
    assert_equal "This feature is only available for pending transactions", flash[:alert]
  end
end
