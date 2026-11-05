require "test_helper"

# The filter is a plain comparison on entries.name: `=` and `!=` match the whole
# name, case sensitively, and a name shaped like "Merchant - DESCRIPTION" is not
# split on its separator.
class Rule::ConditionFilter::TransactionNameTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @rule = rules(:one)
    @account = @family.accounts.create!(
      name: "Rule test", balance: 1000, currency: "USD", accountable: Depository.new
    )
  end

  test "an exact rule does not match a manual row that merely contains the value" do
    manual_entry(name: "Rent insurance")
    manual_entry(name: "Rent")

    matched = matching_entry_ids(operator: "=", value: "Rent")

    assert_equal [ "Rent" ], Entry.where(id: matched).pluck(:name)
  end

  test "an exact rule does not match a row that looks combined" do
    manual_entry(name: "Rent - APARTMENT 4B")

    assert_empty matching_entry_ids(operator: "=", value: "Rent")
  end

  test "an exact rule stays case sensitive" do
    manual_entry(name: "Target")

    assert_empty matching_entry_ids(operator: "=", value: "target")
  end

  test "a not-equal rule still returns manual rows" do
    manual = manual_entry(name: "Rent insurance")
    combined_looking = manual_entry(name: "Target - APARTMENT 4B")

    matched = matching_entry_ids(operator: "!=", value: "Target")

    assert_includes matched, manual.id
    assert_includes matched, combined_looking.id
  end

  test "substring operators are untouched" do
    manual = manual_entry(name: "Rent insurance")

    assert_includes matching_entry_ids(operator: "like", value: "insurance"), manual.id
    assert_empty matching_entry_ids(operator: "like", value: "Costco")
  end

  # A value carrying LIKE metacharacters must be compared literally, not as a
  # pattern, or `= "100% Chiropractic"` would match anything.
  test "wildcards in the value are escaped" do
    manual_entry(name: "Discount - 50% OFF EVERYTHING")

    assert_empty matching_entry_ids(operator: "=", value: "%")
  end

  private
    # @param name [String] the entry name to store
    # @return [Entry] a row with no source, which is what makes entries.source NULL
    def manual_entry(name:)
      create_transaction(account: @account, name: name)
    end

    # @return [Array<String>] entry ids the condition selects, for this account only
    def matching_entry_ids(operator:, value:)
      condition = Rule::Condition.new(
        rule: @rule, condition_type: "transaction_name", operator: operator, value: value
      )

      scope = condition.apply(condition.prepare(@account.transactions))
      scope.map { |transaction| transaction.entry.id }
    end
end
