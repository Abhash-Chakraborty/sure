require "test_helper"
require "ostruct"

class TransactionsHelperTest < ActionView::TestCase
  # build_transaction_extra_details reads `extra` off a Transaction (or anything
  # that responds to :transaction), so a struct is enough to drive it.
  def transaction_with(extra)
    OpenStruct.new(extra: extra)
  end

  # Regression: passing the raw operator straight to t() raised
  # I18n::ArgumentError for nil/blank (an empty key) and resolved a whole
  # translation subtree for a dotted value like "transactions.search".
  test "falls back to the raw operator instead of translating unknown or blank values" do
    assert_equal "", transaction_amount_operator_label(nil)
    assert_equal "foo", transaction_amount_operator_label("foo")
    assert_equal "transactions.search", transaction_amount_operator_label("transactions.search")
  end

  test "falls back to a raw JSON dump for providers with no structured rendering" do
    details = build_transaction_extra_details(transaction_with({ "someprovider" => { "a" => 1 } }))

    assert_equal :raw, details[:kind]
    assert_empty details[:provider_extras]
    assert_equal({ "someprovider" => { "a" => 1 } }, JSON.parse(details[:raw]))
  end

  test "returns nil when the transaction has no extra" do
    assert_nil build_transaction_extra_details(transaction_with({}))
    assert_nil build_transaction_extra_details(transaction_with(nil))
  end

  test "investment_activity_label_name translates the stored label" do
    I18n.with_locale(:ru) do
      assert_equal "Перевод", investment_activity_label_name("Transfer")
      assert_equal "Автоперевод (зачисление)", investment_activity_label_name("Sweep In")
    end
    assert_equal "Buy", investment_activity_label_name("Buy")
  end

  test "investment_activity_label_name falls back to the stored label when it has no translation" do
    assert_equal "Legacy Label", investment_activity_label_name("Legacy Label")
  end
end
