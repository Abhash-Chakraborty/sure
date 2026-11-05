require "test_helper"
require "ostruct"

class DestroyJobTest < ActiveJob::TestCase
  test "destroys the model" do
    model = mock
    model.expects(:destroy).once.returns(true)

    DestroyJob.perform_now(model)
  end

  test "resets scheduled_for_deletion when the destroy fails" do
    model = OpenStruct.new(scheduled_for_deletion: true)
    model.stubs(:destroy).raises(ActiveRecord::RecordNotDestroyed.new("nope"))
    model.expects(:update_column).with(:scheduled_for_deletion, false).once

    DestroyJob.perform_now(model)
  end

  test "an account whose destroy raises is left disabled, not pending_deletion" do
    account = accounts(:depository)
    account.mark_for_deletion!
    account.stubs(:cleanup_transfers).raises(StandardError, "destroy failed")

    assert_no_difference "Account.count" do
      DestroyJob.perform_now(account)
    end

    assert_equal "disabled", account.reload.status
  end

  test "an account whose destroy succeeds is removed" do
    account = accounts(:depository)
    account.mark_for_deletion!

    assert_difference "Account.count", -1 do
      DestroyJob.perform_now(account)
    end
  end

  test "a failed account destroy is recorded in the debug log" do
    account = accounts(:depository)
    account.mark_for_deletion!
    account.stubs(:cleanup_transfers).raises(StandardError, "destroy failed")

    assert_difference -> { DebugLogEntry.count }, 1 do
      DestroyJob.perform_now(account)
    end

    entry = DebugLogEntry.recent.first
    assert_equal "background_jobs", entry.category
    assert_equal "error", entry.level
    assert_equal "DestroyJob", entry.source
    assert_equal account, entry.account
    assert_equal account.family, entry.family
    assert_equal "Account", entry.metadata["record_type"]
    assert_equal account.id, entry.metadata["record_id"]
    assert_equal "StandardError", entry.metadata["error_class"]
    assert_equal "destroy failed", entry.metadata["error_message"]
    assert entry.metadata["backtrace"].present?
  end

  test "a failed destroy is also sent to the Rails log and Sentry" do
    family = families(:dylan_family)
    family.stubs(:destroy).raises(StandardError, "destroy failed")
    Rails.logger.expects(:error).with(regexp_matches(/DestroyJob failed for Family #{family.id}: StandardError: destroy failed/)).once
    Sentry.expects(:capture_exception).with(instance_of(StandardError)).once

    DestroyJob.perform_now(family)
  end

  test "a failed family destroy is recorded against that family" do
    family = families(:dylan_family)
    family.stubs(:destroy).raises(StandardError, "destroy failed")

    assert_difference -> { DebugLogEntry.where(family: family, source: "DestroyJob").count }, 1 do
      DestroyJob.perform_now(family)
    end
  end

  test "a failed destroy of a record without a family is still recorded" do
    model = OpenStruct.new(scheduled_for_deletion: true)
    model.stubs(:destroy).raises(ActiveRecord::RecordNotDestroyed.new("nope"))
    model.stubs(:update_column)

    assert_difference -> { DebugLogEntry.where(family_id: nil, source: "DestroyJob").count }, 1 do
      DestroyJob.perform_now(model)
    end
  end

  test "a successful destroy writes no debug log entry" do
    account = accounts(:depository)
    account.mark_for_deletion!

    assert_no_difference -> { DebugLogEntry.count } do
      DestroyJob.perform_now(account)
    end
  end

  test "a destroy that a callback aborts is recorded and resets the flag" do
    model = OpenStruct.new(scheduled_for_deletion: true)
    model.stubs(:destroy).returns(false)
    model.expects(:update_column).with(:scheduled_for_deletion, false).once

    assert_difference -> { DebugLogEntry.where(source: "DestroyJob").count }, 1 do
      DestroyJob.perform_now(model)
    end

    assert_equal "ActiveRecord::RecordNotDestroyed", DebugLogEntry.recent.first.metadata["error_class"]
  end

  test "an account whose destroy deadlocks once is deleted on the retry" do
    account = accounts(:depository)
    account.mark_for_deletion!
    Account.any_instance.stubs(:cleanup_transfers).raises(ActiveRecord::Deadlocked, "deadlock detected").then.returns(nil)

    assert_difference "Account.count", -1 do
      perform_enqueued_jobs { DestroyJob.perform_later(account) }
    end
  end

  test "an account stays pending_deletion while a deadlock is retried" do
    account = accounts(:depository)
    account.mark_for_deletion!
    account.stubs(:cleanup_transfers).raises(ActiveRecord::Deadlocked, "deadlock detected")

    assert_enqueued_with(job: DestroyJob, args: [ account ]) do
      DestroyJob.perform_now(account)
    end

    assert_equal "pending_deletion", account.reload.status
  end

  test "an account whose deadlock outlasts the retries is recorded and left disabled" do
    account = accounts(:depository)
    account.mark_for_deletion!
    Account.any_instance.stubs(:cleanup_transfers).raises(ActiveRecord::Deadlocked, "deadlock detected")

    assert_difference -> { DebugLogEntry.where(source: "DestroyJob").count }, 1 do
      perform_enqueued_jobs { DestroyJob.perform_later(account) }
    end

    assert_equal "ActiveRecord::Deadlocked", DebugLogEntry.recent.first.metadata["error_class"]
    assert_equal "disabled", account.reload.status
  end

  test "an account whose destroy a callback aborts is recorded with the reason and left disabled" do
    account = accounts(:depository)
    account.mark_for_deletion!
    account.define_singleton_method(:cleanup_transfers) do
      errors.add(:base, "Still in use")
      throw :abort
    end

    DestroyJob.perform_now(account)

    entry = DebugLogEntry.recent.first
    assert_equal "ActiveRecord::RecordNotDestroyed", entry.metadata["error_class"]
    assert_equal [ "Still in use" ], entry.metadata["record_errors"]
    assert_equal "disabled", account.reload.status
  end

  test "an account whose owner left the family is still left disabled after a failed destroy" do
    account = accounts(:depository)
    account.mark_for_deletion!
    account.owner.update_column(:family_id, families(:empty).id)
    account.stubs(:cleanup_transfers).raises(StandardError, "destroy failed")

    assert_difference "DebugLogEntry.count", 1 do
      DestroyJob.perform_now(account)
    end

    assert_equal "disabled", account.reload.status
    assert_equal "StandardError", DebugLogEntry.order(:created_at).last.metadata["error_class"]
  end

  test "an error after the account delete committed is recorded as itself" do
    account = accounts(:depository)
    account.mark_for_deletion!
    account.stubs(:move_account_statements_to_inbox).raises(StandardError, "inbox move failed")

    assert_difference -> { DebugLogEntry.where(source: "DestroyJob").count }, 1 do
      DestroyJob.perform_now(account)
    end

    entry = DebugLogEntry.recent.first
    assert_equal "StandardError", entry.metadata["error_class"]
    assert_equal account.family, entry.family
    assert_nil entry.account_id
    assert_not Account.exists?(account.id)
  end

  test "a reset that the database rejects is recorded and does not raise out of the job" do
    model = OpenStruct.new(scheduled_for_deletion: true)
    model.stubs(:destroy).raises(StandardError, "destroy failed")
    model.stubs(:update_column).raises(ActiveRecord::RecordNotUnique, "duplicate key")

    assert_difference -> { DebugLogEntry.where(source: "DestroyJob").count }, 2 do
      assert_nothing_raised { DestroyJob.perform_now(model) }
    end

    assert_equal %w[StandardError ActiveRecord::RecordNotUnique].sort,
      DebugLogEntry.where(source: "DestroyJob").map { |entry| entry.metadata["error_class"] }.sort
  end

  test "the flag is reset even when recording the failure raises" do
    model = OpenStruct.new(scheduled_for_deletion: true)
    model.stubs(:destroy).raises(StandardError, "destroy failed")
    model.expects(:update_column).with(:scheduled_for_deletion, false).once
    DebugLogEntry.stubs(:capture).raises(StandardError, "log write failed")

    assert_raises(StandardError) { DestroyJob.perform_now(model) }
  end

  test "a deadlock after the account delete committed is recorded instead of retried" do
    account = accounts(:depository)
    account.mark_for_deletion!
    account.stubs(:move_account_statements_to_inbox).raises(ActiveRecord::Deadlocked, "deadlock detected")

    assert_no_enqueued_jobs(only: DestroyJob) do
      assert_difference -> { DebugLogEntry.where(source: "DestroyJob").count }, 1 do
        DestroyJob.perform_now(account)
      end
    end

    assert_equal "ActiveRecord::Deadlocked", DebugLogEntry.recent.first.metadata["error_class"]
    assert_not Account.exists?(account.id)
  end

  test "inherits the deferred-enqueue policy from ApplicationJob" do
    account = accounts(:depository)
    enqueued_mid_transaction = nil

    ActiveRecord::Base.transaction do
      DestroyJob.perform_later(account)
      enqueued_mid_transaction = enqueued_jobs.any? { |job| job[:job] == DestroyJob }
    end

    assert_not enqueued_mid_transaction, "DestroyJob enqueued before the transaction committed"
    assert_enqueued_with job: DestroyJob
  end
end
