# Reminders for money with a date on it: loans to collect, investments that
# mature, money owed. Everything is scoped to the signed-in family.
class RemindersController < ApplicationController
  before_action :require_non_guest!, except: :index
  before_action :set_reminder, only: %i[edit update destroy done reopen]

  UPCOMING_WINDOW = 30.days
  DONE_LIMIT = 20

  def index
    @today = Current.family.local_date
    reminders = Current.family.reminders.includes(:account)

    @overdue = reminders.overdue(@today).order(:due_on, :title)
    upcoming = reminders.upcoming(@today).order(:due_on, :title).to_a
    @soon, @later = upcoming.partition { |reminder| reminder.due_on <= @today + UPCOMING_WINDOW }
    @done = reminders.completed.order(completed_at: :desc).limit(DONE_LIMIT)

    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t(".title"), nil ] ]
  end

  def new
    @reminder = Current.family.reminders.new(
      kind: params[:kind].presence_in(Reminder::KINDS) || "money_lent",
      currency: Current.family.primary_currency_code,
      due_on: Current.family.local_date + 1.month
    )
  end

  def create
    @reminder = Current.family.reminders.new(reminder_params)
    @reminder.currency = Current.family.primary_currency_code if @reminder.currency.blank?

    if @reminder.save
      redirect_with_notice t(".created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @reminder.update(reminder_params)
      redirect_with_notice t(".updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @reminder.destroy!
    redirect_to reminders_path, notice: t(".deleted"), status: :see_other
  end

  def done
    @reminder.mark_done!

    notice = if @reminder.completed?
      t(".completed", title: @reminder.title)
    else
      t(".next_date", title: @reminder.title, date: helpers.format_date(@reminder.due_on))
    end
    redirect_to reminders_path, notice: notice, status: :see_other
  end

  def reopen
    @reminder.reopen!
    redirect_to reminders_path, notice: t(".reopened", title: @reminder.title), status: :see_other
  end

  private
    def set_reminder
      @reminder = Current.family.reminders.find(params[:id])
    end

    def reminder_params
      permitted = params.require(:reminder).permit(
        :title, :kind, :counterparty, :amount, :currency, :due_on, :repeat,
        :remind_days_before, :notes, :account_id
      )

      # Only the family's own accounts can be linked.
      if permitted.key?(:account_id)
        permitted[:account_id] = Current.family.accounts.where(id: permitted[:account_id].presence).pick(:id)
      end

      permitted
    end

    def redirect_with_notice(notice)
      flash[:notice] = notice

      respond_to do |format|
        format.html { redirect_to reminders_path }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, reminders_path) }
      end
    end
end
