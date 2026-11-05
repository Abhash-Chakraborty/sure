require "test_helper"

class SyncAllProvidersJobTest < ActiveJob::TestCase
  test "provider-wide sync syncs the family" do
    family = families(:dylan_family)

    Family.stubs(:find_by).with(id: family.id).returns(family)
    family.expects(:sync_later)

    SyncAllProvidersJob.perform_now(family.id)
  end

  test "provider-wide sync ignores a deleted family" do
    Family.expects(:find_by).returns(nil)

    Family.any_instance.expects(:sync_later).never

    SyncAllProvidersJob.perform_now("missing")
  end
end
