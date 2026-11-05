# Dates to remember about money: a loan to a friend, a deposit that matures,
# money someone owes. ReminderNotificationJob emails a daily digest of the
# ones coming due; last_notified_on keeps it from repeating itself.
class CreateReminders < ActiveRecord::Migration[8.1]
  def change
    create_table :reminders, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :account, foreign_key: { on_delete: :nullify }, type: :uuid

      t.string :title, null: false
      t.string :kind, null: false, default: "other"
      t.string :counterparty
      t.decimal :amount, precision: 19, scale: 4
      t.string :currency, null: false
      t.date :due_on, null: false
      t.string :repeat, null: false, default: "none"
      t.integer :remind_days_before, null: false, default: 1
      t.text :notes
      t.datetime :completed_at
      t.date :last_notified_on

      t.timestamps
    end

    add_index :reminders, [ :family_id, :completed_at, :due_on ]
  end
end
