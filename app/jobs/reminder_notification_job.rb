# Emails each family member a digest of reminders coming due, once a day.
# A reminder joins the digest once it is within its remind_days_before
# window; an overdue one comes back every Reminder::OVERDUE_RESEND_DAYS days
# until it is marked done. last_notified_on makes a second run on the same
# day send nothing.
class ReminderNotificationJob < ApplicationJob
  queue_as :scheduled

  def perform
    return unless Setting.mail_server_configured?

    Family.where(id: Reminder.pending.select(:family_id)).find_each do |family|
      notify(family)
    rescue StandardError => e
      Rails.logger.error("ReminderNotificationJob family #{family.id} failed: #{e.class}: #{e.message}")
    end
  end

  private
    def notify(family)
      today = family.local_date
      reminders = family.reminders.to_notify(today).order(:due_on, :title).to_a
      return if reminders.empty?

      recipients = family.users.where(active: true).to_a
      return if recipients.empty?

      recipients.each { |user| ReminderMailer.due(user, reminders).deliver_later }

      Reminder.where(id: reminders.map(&:id)).update_all(last_notified_on: today, updated_at: Time.current)
    end
end
