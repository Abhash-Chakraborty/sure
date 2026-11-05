require "test_helper"

class SyncAllJobTest < ActiveJob::TestCase
  test "scheduled sync syncs each family" do
    family = families(:dylan_family)
    Family.stubs(:find_each).yields(family)
    family.expects(:sync_later)

    SyncAllJob.perform_now
  end
end
