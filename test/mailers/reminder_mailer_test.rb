require "test_helper"

class ReminderMailerTest < ActionMailer::TestCase
  setup do
    @user = users(:family_admin)
    travel_to Time.zone.parse("2026-11-05 09:00")
    today = @user.family.local_date
    @reminders = [
      @user.family.reminders.create!(title: "Loan to Ravi", counterparty: "Ravi", kind: "money_lent", amount: 5000, currency: "INR", due_on: today - 2),
      @user.family.reminders.create!(title: "Fixed deposit matures", kind: "investment", currency: "INR", due_on: today + 1)
    ]
  end

  test "lists what is due with a link to the reminders page" do
    mail = ReminderMailer.due(@user, @reminders)

    assert_equal [ @user.email ], mail.to
    assert_equal "2 reminders are due", mail.subject

    [ mail.html_part.body.decoded, mail.text_part.body.decoded ].each do |body|
      assert_match "Loan to Ravi", body
      assert_match "Ravi", body
      assert_match "2 days overdue", body
      assert_match "Fixed deposit matures", body
      assert_match "Due tomorrow", body
      assert_match %r{/reminders}, body
    end
  end

  test "sends through the stored mail server" do
    Setting.smtp_address = "smtp.example.com"

    with_env_overrides("SMTP_ADDRESS" => nil) do
      mail = ReminderMailer.due(@user, @reminders)

      assert_emails(1) { mail.deliver_now }
      assert_equal "smtp.example.com", mail.delivery_method.settings[:address]
    end
  ensure
    Setting.smtp_address = nil
  end
end
