require "test_helper"

class Family::SyncerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  setup do
    @family = families(:dylan_family)
  end

  test "syncs provider items and manual accounts" do
    family_sync = syncs(:family)

    manual_accounts_count = @family.accounts.manual.count
    syncer = Family::Syncer.new(@family)

    Account.any_instance
           .expects(:sync_later)
           .with(parent_sync: family_sync, window_start_date: nil, window_end_date: nil)
           .times(manual_accounts_count)

    syncable_item_associations.each do |association|
      association.klass.any_instance
                 .expects(:sync_later)
                 .with(parent_sync: family_sync, window_start_date: nil, window_end_date: nil)
                 .times(@family.public_send(association.name).syncable.count)
    end

    syncer.perform_sync(family_sync)

    assert_equal "completed", family_sync.reload.status
  end

  test "applies rules in one ordered run per family after sync" do
    syncer = Family::Syncer.new(@family)

    assert_enqueued_with(job: ApplyRulesJob, args: [ @family ]) do
      syncer.perform_post_sync
    end
    assert_no_enqueued_jobs(only: RuleJob)
  end

  # Issue #2925: merchants whose website arrived before Brandfetch was
  # configured get their logo on the next sync.
  test "backfills provider merchant logos after sync" do
    @family.expects(:backfill_provider_merchant_logos).once

    Family::Syncer.new(@family).perform_post_sync
  end

  test "a logo backfill failure does not stop rules from being applied" do
    ProviderMerchant.stubs(:backfill_logos).raises(StandardError, "boom")

    assert_enqueued_with(job: ApplyRulesJob, args: [ @family ]) do
      Family::Syncer.new(@family).perform_post_sync
    end
  end

  private
    def syncable_item_associations
      Family.reflect_on_all_associations(:has_many).select do |association|
        association.name.to_s.end_with?("_items") &&
          association.klass.included_modules.include?(Syncable)
      rescue NameError
        false
      end
    end
end
