require "test_helper"

class Transaction::MergeWithDuplicateTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @account = accounts(:depository)
    @family  = @account.family

    @category_a = categories(:food_and_drink)

    # Entry carrying a duplicate suggestion (formerly a bank-synced pending transaction)
    @pending_entry = create_transaction(
      account:     @account,
      name:        "Starbucks Pending",
      date:        3.days.ago.to_date,
      amount:      10,
      currency:    "USD",
      external_id: "enable_banking_PDNG123",
      source:      "enable_banking",
      category:    @category_a
    )

    # Posted (booked) entry — the canonical settled transaction from the bank
    @posted_entry = create_transaction(
      account:  @account,
      name:     "STARBUCKS CORP",
      date:     1.day.ago.to_date,
      amount:   10,
      currency: "USD",
      external_id: "enable_banking_BOOK456",
      source:      "enable_banking"
    )

    # Wire up the duplicate suggestion on the pending transaction
    @pending_entry.transaction.update!(
      extra: (@pending_entry.transaction.extra || {}).merge(
        "potential_posted_match" => {
          "entry_id"      => @posted_entry.id,
          "reason"        => "fuzzy_amount_match",
          "posted_amount" => "10.0",
          "confidence"    => "medium",
          "detected_at"   => Date.current.to_s,
          "dismissed"     => false
        }
      )
    )
  end

  # --- dismiss_duplicate_suggestion! ---

  test "dismiss_duplicate_suggestion! sets dismissed flag on the match" do
    @pending_entry.transaction.dismiss_duplicate_suggestion!
    assert_equal true, @pending_entry.transaction.reload.extra.dig("potential_posted_match", "dismissed")
  end

  test "dismiss_duplicate_suggestion! makes has_potential_duplicate? return false" do
    @pending_entry.transaction.dismiss_duplicate_suggestion!
    assert_not @pending_entry.transaction.reload.has_potential_duplicate?
  end

  test "dismiss_duplicate_suggestion! returns false when no suggestion is present" do
    @pending_entry.transaction.update!(extra: {})
    assert_equal false, @pending_entry.transaction.dismiss_duplicate_suggestion!
  end

  # --- clear_duplicate_suggestion! ---

  test "clear_duplicate_suggestion! removes potential_posted_match key entirely" do
    @pending_entry.transaction.clear_duplicate_suggestion!
    assert_nil @pending_entry.transaction.reload.extra["potential_posted_match"]
  end

  test "clear_duplicate_suggestion! returns false when no suggestion is present" do
    @pending_entry.transaction.update!(extra: {})
    assert_equal false, @pending_entry.transaction.clear_duplicate_suggestion!
  end

  # --- pending_duplicate_candidates ---

  test "pending_duplicate_candidates returns Entry.none when transaction is not pending" do
    @pending_entry.transaction.update!(extra: {})
    assert_equal [], @pending_entry.transaction.pending_duplicate_candidates.to_a
  end
end
