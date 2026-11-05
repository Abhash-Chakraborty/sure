require "test_helper"

class IdentifyRecurringTransactionsJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @scheduled_at = Time.current.to_f
  end

  test "skips identification while an account sync is in flight" do
    Sync.create!(syncable: accounts(:depository), status: :syncing)

    RecurringTransaction::Identifier.any_instance.expects(:identify_recurring_patterns).never

    IdentifyRecurringTransactionsJob.new.perform(@family.id, @scheduled_at)
  end

  test "runs identification when no provider syncs are in flight" do
    # Sanity: there are no incomplete syncs in the fixture set by default.
    Sync.for_family(@family).incomplete.find_each(&:destroy)

    RecurringTransaction::Identifier.any_instance.expects(:identify_recurring_patterns).once

    IdentifyRecurringTransactionsJob.new.perform(@family.id, @scheduled_at)
  end

  test "skips when family is missing" do
    RecurringTransaction::Identifier.any_instance.expects(:identify_recurring_patterns).never

    IdentifyRecurringTransactionsJob.new.perform(SecureRandom.uuid, @scheduled_at)
  end

  test "skips when a newer scheduled run supersedes this one" do
    # Rails.cache is NullStore in the test env (writes are no-ops), so we stub
    # the read directly to simulate a newer scheduled-at landing in the cache
    # between this job being enqueued and being picked up.
    cache_key = "recurring_transaction_identify:#{@family.id}"
    Rails.cache.stubs(:read).with(cache_key).returns(@scheduled_at + 10)

    RecurringTransaction::Identifier.any_instance.expects(:identify_recurring_patterns).never

    assert_nil IdentifyRecurringTransactionsJob.new.perform(@family.id, @scheduled_at)
  end
end
