require "test_helper"

class ReminderTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @today = Date.new(2026, 11, 5)
  end

  test "requires a title and a due date" do
    reminder = @family.reminders.new(currency: "INR")

    assert_not reminder.valid?
    assert reminder.errors.added?(:title, :blank)
    assert reminder.errors.added?(:due_on, :blank)
  end

  test "rejects an unknown kind, repeat and a notice longer than 30 days" do
    reminder = build_reminder(kind: "gift", repeat: "daily", remind_days_before: 31)

    assert_not reminder.valid?
    assert reminder.errors.include?(:kind)
    assert reminder.errors.include?(:repeat)
    assert reminder.errors.include?(:remind_days_before)
  end

  test "cannot link another family's account" do
    reminder = build_reminder(account: Account.new(family: families(:empty), name: "Elsewhere"))

    assert_not reminder.valid?
    assert reminder.errors.include?(:account)
    assert build_reminder(account: accounts(:other_asset)).valid?
  end

  test "marking a one-off done puts it away" do
    reminder = create_reminder(due_on: @today, last_notified_on: @today)

    reminder.mark_done!

    assert reminder.completed?
    assert_equal @today, reminder.due_on
    assert_includes @family.reminders.completed, reminder
  end

  test "marking a repeating reminder done moves it to the next date" do
    monthly = create_reminder(due_on: Date.new(2026, 1, 31), repeat: "monthly", last_notified_on: Date.new(2026, 1, 30))
    weekly = create_reminder(due_on: @today, repeat: "weekly")
    yearly = create_reminder(due_on: @today, repeat: "yearly")

    [ monthly, weekly, yearly ].each(&:mark_done!)

    assert_equal Date.new(2026, 2, 28), monthly.due_on
    assert_nil monthly.last_notified_on
    assert_not monthly.completed?
    assert_equal @today + 7, weekly.due_on
    assert_equal Date.new(2027, 11, 5), yearly.due_on
  end

  test "reopening a done reminder puts it back on the list" do
    reminder = create_reminder(due_on: @today, completed_at: Time.current)

    reminder.reopen!

    assert_includes @family.reminders.pending, reminder
  end

  test "scopes split overdue, upcoming and completed" do
    overdue = create_reminder(due_on: @today - 1)
    today = create_reminder(due_on: @today)
    later = create_reminder(due_on: @today + 40)
    done = create_reminder(due_on: @today - 5, completed_at: Time.current)

    assert_equal [ overdue ], @family.reminders.overdue(@today).to_a
    assert_equal [ today, later ].sort_by(&:due_on), @family.reminders.upcoming(@today).order(:due_on).to_a
    assert_equal [ done ], @family.reminders.completed.to_a
    assert_equal [ overdue, today ].map(&:id).sort, @family.reminders.needing_attention(@today).pluck(:id).sort
  end

  test "describes when it is due" do
    assert_equal "Due today", build_reminder(due_on: @today).due_label(@today)
    assert_equal "Due tomorrow", build_reminder(due_on: @today + 1).due_label(@today)
    assert_equal "Due in 5 days", build_reminder(due_on: @today + 5).due_label(@today)
    assert_equal "3 days overdue", build_reminder(due_on: @today - 3).due_label(@today)
  end

  private
    def build_reminder(**attrs)
      @family.reminders.new({ title: "Loan to Ravi", kind: "money_lent", currency: "INR", due_on: @today }.merge(attrs))
    end

    def create_reminder(**attrs)
      build_reminder(**attrs).tap(&:save!)
    end
end
