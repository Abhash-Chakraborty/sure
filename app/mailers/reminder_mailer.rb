class ReminderMailer < ApplicationMailer
  # The daily digest from ReminderNotificationJob: what is due soon or overdue.
  def due(user, reminders)
    @user = user
    @reminders = reminders
    @today = user.family.local_date
    @reminders_url = reminders_url

    mail to: user.email, subject: t(".subject", count: reminders.size)
  end
end
