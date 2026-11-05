# A date to remember about money: a loan to a friend, an FD that matures,
# money someone owes, a bill paid outside the bank. The Reminders page lists
# them, and ReminderNotificationJob emails a digest when they come due.
class Reminder < ApplicationRecord
  include Monetizable

  KINDS = %w[money_lent money_owed_to_me investment bill other].freeze
  REPEATS = %w[none weekly monthly yearly].freeze
  # An overdue reminder is emailed again at most this often.
  OVERDUE_RESEND_DAYS = 3

  belongs_to :family
  belongs_to :account, optional: true

  monetize :amount

  validates :title, presence: true, length: { maximum: 200 }
  validates :due_on, :currency, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :repeat, inclusion: { in: REPEATS }
  validates :remind_days_before, numericality: { only_integer: true, in: 0..30 }
  validates :amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :counterparty, length: { maximum: 200 }
  validates :notes, length: { maximum: 2000 }
  validate :account_in_family

  # A new date starts a new round of emails.
  before_update -> { self.last_notified_on = nil }, if: :will_save_change_to_due_on?

  scope :pending, -> { where(completed_at: nil) }
  scope :completed, -> { where.not(completed_at: nil) }
  scope :overdue, ->(today = Date.current) { pending.where(due_on: ...today) }
  scope :upcoming, ->(today = Date.current) { pending.where(due_on: today..) }
  # Overdue or due today: what the nav badge counts.
  scope :needing_attention, ->(today = Date.current) { pending.where(due_on: ..today) }

  # Pending reminders inside their reminder window that haven't been emailed
  # today. Overdue ones go out again only every OVERDUE_RESEND_DAYS days.
  scope :to_notify, ->(today) {
    pending
      .where("reminders.due_on - reminders.remind_days_before <= ?", today)
      .where(
        "reminders.last_notified_on IS NULL " \
        "OR (reminders.due_on >= :today AND reminders.last_notified_on < :today) " \
        "OR (reminders.due_on < :today AND reminders.last_notified_on <= :resend_before)",
        today: today, resend_before: today - OVERDUE_RESEND_DAYS
      )
  }

  def repeating?
    repeat.present? && repeat != "none"
  end

  def completed?
    completed_at.present?
  end

  # Done with this one. A repeating reminder moves to its next date and
  # starts emailing afresh; a one-off is put away as done.
  def mark_done!
    if repeating?
      update!(due_on: next_due_on)
    else
      update!(completed_at: Time.current)
    end
  end

  def reopen!
    update!(completed_at: nil)
  end

  def next_due_on
    case repeat
    when "weekly" then due_on + 1.week
    when "monthly" then due_on.next_month
    when "yearly" then due_on.next_year
    else due_on
    end
  end

  # :overdue, :today or :upcoming, against the family's calendar day.
  def due_state(today)
    if due_on < today then :overdue
    elsif due_on == today then :today
    else :upcoming
    end
  end

  # "Due today", "Due tomorrow", "Due in 5 days", "3 days overdue".
  def due_label(today)
    days = (due_on - today).to_i

    case due_state(today)
    when :overdue then I18n.t("reminders.due.overdue", count: -days)
    when :today then I18n.t("reminders.due.today")
    else I18n.t("reminders.due.in_days", count: days)
    end
  end

  private
    def account_in_family
      return if account.nil? || account.family_id == family_id

      errors.add(:account, :invalid)
    end
end
