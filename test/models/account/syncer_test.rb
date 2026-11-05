require "test_helper"

class Account::SyncerTest < ActiveSupport::TestCase
  test "post-sync auto matches only transfers touching the synced account" do
    account = accounts(:depository)

    account.family.expects(:auto_match_transfers!).with(account: account).once

    Account::Syncer.new(account).perform_post_sync
  end
end
