require "test_helper"

class ReminderNotificationJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @recipients = @family.users.where(active: true).count
    Setting.smtp_address = "smtp.example.com"
    travel_to Time.zone.parse("2026-11-05 09:00")
    @today = @family.local_date
  end

  teardown do
    Setting.smtp_address = nil
  end

  test "emails each family member once and stamps the reminders" do
    due = create_reminder(due_on: @today + 1, remind_days_before: 1)
    overdue = create_reminder(due_on: @today - 10)

    assert_enqueued_emails(@recipients) { perform }

    assert_equal @today, due.reload.last_notified_on
    assert_equal @today, overdue.reload.last_notified_on
  end

  test "a second run on the same day sends nothing" do
    create_reminder(due_on: @today)

    perform
    assert_no_enqueued_emails { perform }
  end

  test "waits for the reminder window" do
    create_reminder(due_on: @today + 5, remind_days_before: 3)

    assert_no_enqueued_emails { perform }

    travel 2.days
    assert_enqueued_emails(@recipients) { perform }
  end

  test "sends overdue reminders again only every three days" do
    reminder = create_reminder(due_on: @today - 10, last_notified_on: @today - 2)

    assert_no_enqueued_emails { perform }

    reminder.update_column(:last_notified_on, @today - 3)
    assert_enqueued_emails(@recipients) { perform }
  end

  test "a reminder still in its window is sent each day until it is due" do
    reminder = create_reminder(due_on: @today + 1, remind_days_before: 2, last_notified_on: @today - 1)

    assert_enqueued_emails(@recipients) { perform }
    assert_equal @today, reminder.reload.last_notified_on
  end

  test "skips done reminders" do
    create_reminder(due_on: @today, completed_at: Time.current)

    assert_no_enqueued_emails { perform }
  end

  test "sends nothing without a mail server" do
    Setting.smtp_address = nil
    reminder = create_reminder(due_on: @today)

    assert_no_enqueued_emails { perform }
    assert_nil reminder.reload.last_notified_on
  end

  private
    def perform
      with_env_overrides("SMTP_ADDRESS" => nil) { ReminderNotificationJob.perform_now }
    end

    def create_reminder(**attrs)
      @family.reminders.create!({ title: "Loan to Ravi", kind: "money_lent", amount: 5000, currency: "INR", due_on: @today }.merge(attrs))
    end
end
