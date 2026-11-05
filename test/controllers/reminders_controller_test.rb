require "test_helper"

class RemindersControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @reminder = @family.reminders.create!(
      title: "Loan to Ravi", counterparty: "Ravi", kind: "money_lent",
      amount: 5000, currency: "INR", due_on: Date.current - 2
    )
  end

  test "lists reminders by section" do
    @family.reminders.create!(title: "FD matures", kind: "investment", currency: "INR", due_on: Date.current + 60)

    get reminders_url

    assert_response :success
    assert_select "h2", text: /Overdue/
    assert_select "h2", text: /Later/
    assert_select "#" + dom_id(@reminder), text: /Loan to Ravi/
  end

  test "shows a count on the nav entry when something is overdue" do
    get reminders_url

    assert_select "a[href='#{reminders_path}'] span", text: "1"
  end

  test "new opens the form" do
    get new_reminder_url

    assert_response :success
    assert_select "form[action='#{reminders_path}']"
  end

  test "creates a reminder in the family" do
    assert_difference -> { @family.reminders.count }, 1 do
      post reminders_url, params: { reminder: {
        title: "Deposit back from landlord", kind: "money_owed_to_me", counterparty: "Landlord",
        amount: "20000", currency: "INR", due_on: (Date.current + 10).iso8601, repeat: "none",
        remind_days_before: "3", account_id: accounts(:other_asset).id
      } }
    end

    assert_redirected_to reminders_url
    reminder = @family.reminders.order(:created_at).last
    assert_equal "Deposit back from landlord", reminder.title
    assert_equal 3, reminder.remind_days_before
    assert_equal accounts(:other_asset), reminder.account
  end

  test "an invalid reminder renders the form again" do
    assert_no_difference -> { Reminder.count } do
      post reminders_url, params: { reminder: { title: "", due_on: "" } }
    end

    assert_response :unprocessable_entity
  end

  test "updates a reminder" do
    patch reminder_url(@reminder), params: { reminder: { title: "Loan to Ravi (half back)", amount: "2500" } }

    assert_redirected_to reminders_url
    assert_equal "Loan to Ravi (half back)", @reminder.reload.title
    assert_equal 2500, @reminder.amount
  end

  test "mark done completes a one-off and reopen brings it back" do
    patch done_reminder_url(@reminder)

    assert_redirected_to reminders_url
    assert @reminder.reload.completed?

    patch reopen_reminder_url(@reminder)

    assert_not @reminder.reload.completed?
  end

  test "mark done moves a repeating reminder to its next date" do
    @reminder.update!(repeat: "monthly")
    due_on = @reminder.due_on

    patch done_reminder_url(@reminder)

    assert_equal due_on.next_month, @reminder.reload.due_on
    assert_not @reminder.completed?
  end

  test "deletes a reminder" do
    assert_difference -> { Reminder.count }, -1 do
      delete reminder_url(@reminder)
    end

    assert_redirected_to reminders_url
  end

  test "cannot touch another family's reminder" do
    other = families(:empty).reminders.create!(title: "Not yours", currency: "USD", due_on: Date.current)

    patch reminder_url(other), params: { reminder: { title: "Mine now" } }
    assert_response :not_found

    delete reminder_url(other)
    assert_response :not_found

    get reminders_url
    assert_select "#" + dom_id(other), count: 0
    assert_equal "Not yours", other.reload.title
  end

  test "ignores an account from another family" do
    foreign = families(:empty).accounts.create!(name: "Elsewhere", balance: 0, currency: "USD", accountable: OtherAsset.new)

    patch reminder_url(@reminder), params: { reminder: { account_id: foreign.id } }

    assert_nil @reminder.reload.account
  end
end
