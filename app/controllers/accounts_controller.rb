class AccountsController < ApplicationController
  include StreamExtensions

  before_action :set_account, only: %i[show sparkline sync set_default remove_default clear_filter]
  before_action :set_manageable_account, only: %i[logo_options toggle_active toggle_exclude_from_reports destroy unlink confirm_unlink select_provider]
  before_action :ensure_linked_account, only: %i[confirm_unlink unlink]
  include Periodable

  helper_method :visible_card_accounts

  def index
    @accessible_account_ids = Current.user.accessible_accounts.pluck(:id)
    @manual_accounts = family.accounts
          .listable_manual
          .where(id: @accessible_account_ids)
          .with_attached_logo
          .includes(:accountable, :account_providers)
          .order(:name)
    preload_latest_sync_metadata_for_index!

    # Prevent Turbo Drive from caching this page to ensure fresh account lists
    expires_now
    render layout: "settings"
  end

  def new
    # Get all registered providers with any credentials configured
    @provider_configs = Provider::Factory.registered_adapters.flat_map do |adapter_class|
      adapter_class.connection_configs(family: family)
    end
  end

  def sync_all
    family.sync_later
    redirect_to accounts_path, notice: t("accounts.sync_all.syncing")
  end

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.accounts"), accounts_path ],
      [ @account.name, nil ]
    ]
    @chart_view = params[:chart_view] || "balance"
    @tab = params[:tab]
    # One reference date for everything on the page that is date-sensitive:
    # the chart, its projection, the cards and the Schedule tab. Read
    # separately, a render crossing midnight shows a chart projecting from one
    # date beside a table shaded against another.
    @as_of = Date.current
    @accessible_account_ids = Current.user.accessible_accounts.pluck(:id).to_set
    @q = activity_search_params
    entries = @account.entries.excluding_split_parents.search(@q, family).reverse_chronological.includes(:entryable)
    if statement_tab_active?
      build_statement_tab_data
      return render_statement_tab_frame if statement_tab_frame_request?
    end

    # Only for a response that will actually show the chart card. The payload
    # runs the schedule and the projection; a Turbo frame request for the
    # activity feed's `entries` frame (its pagination) renders the whole page
    # and keeps one frame, so building it there was a full simulation per page
    # turn for nothing. Same reasoning as the statements-frame return above.
    #
    # The chart and the Schedule tab's forecast card read the same projection,
    # so it is built once here and handed to both. The Extra repayments tab's
    # projection is built on the same date, and only when there is an extra
    # to model; the chart draws it beside the others.
    if @account.accountable.is_a?(Loan)
      @loan_projection = @account.loan.payoff_projection(as_of: @as_of)
      @extra_repayment = loan_extra_repayment
      if @extra_repayment.applied?
        @loan_extra_projection = @account.loan.payoff_projection(as_of: @as_of, extra: @extra_repayment.amount,
                                                                 extra_frequency: @extra_repayment.frequency)
      end
    end
    @loan_chart = loan_payoff_chart(@account, as_of: @as_of, period: @period, projection: @loan_projection,
                                    extra_projection: @loan_extra_projection) if chart_card_requested?

    per_page = safe_per_page(stored_per_page_default)
    store_per_page!(per_page) if params[:per_page].present?

    @pagy, @entries = pagy(
      entries,
      limit: per_page,
      params: request.query_parameters.except("tab").merge("tab" => "activity")
    )

    # Preload transfer associations only for Transaction entries
    txn_entryables = @entries.filter_map { |e| e.entryable if e.entryable_type == "Transaction" }
    ActiveRecord::Associations::Preloader.new(
      records: txn_entryables,
      associations: {
        transfer_as_outflow: { inflow_transaction: { entry: :account } },
        # :category for the read-only category an inflow leg shows (Transaction#category_set_on_transfer_outflow?)
        transfer_as_inflow: { outflow_transaction: [ :category, { entry: :account } ] }
      }
    ).call

    Transaction::ActivitySecurityPreloader.new(@entries).preload

    # The preload and split-parent lookup below are intentionally scoped to the
    # current page (@entries) — only this page is rendered, so a child entry
    # whose split parent sits on another page deliberately won't resolve it.
    transactions = @entries.filter_map { |e| e.entryable if e.transaction? }
    if transactions.any?
      ActiveRecord::Associations::Preloader.new(
        records: transactions,
        associations: [ :transfer_as_inflow, :transfer_as_outflow, :category, { merchant: { logo_attachment: :blob } }, :tags ]
      ).call
    end

    trades = @entries.filter_map { |e| e.entryable if e.entryable_type == "Trade" }
    if trades.any?
      ActiveRecord::Associations::Preloader.new(
        records: trades,
        associations: [ :security ]
      ).call
    end

    @transfer_hint_transaction_ids = Current.family.transaction_ids_with_transfer_candidates(transactions, user: Current.user)

    entry_ids = @entries.map(&:id)
    @split_parent_entry_ids = Entry.split_parent_ids_among(entry_ids)

    # Load split parent entries for grouped display (only when grouping is enabled)
    @split_parents = if Current.user.show_split_grouped?
      split_parent_ids = @entries.filter_map(&:parent_entry_id).uniq
      if split_parent_ids.any?
        Entry.where(id: split_parent_ids)
             .includes(:account, entryable: [ :category, { merchant: { logo_attachment: :blob } } ])
             .index_by(&:id)
      else
        {}
      end
    else
      {}
    end

    @activity_feed_data = Account::ActivityFeedData.new(@account, @entries, split_parents: @split_parents)
  end

  def sync
    unless @account.syncing?
      if @account.linked?
        # Sync all provider items for this account
        # Each provider item will trigger an account sync when complete
        @account.account_providers.each do |account_provider|
          item = account_provider.adapter&.item
          next unless item && !item.syncing?

          item.sync_later
        end
      else
        # Manual accounts just need balance materialization
        @account.sync_later
      end
    end

    redirect_to account_path(@account)
  end

  # Mirrors TransactionsController#clear_filter, but simpler: the account
  # activity feed has no cross-request stored filters to update, so this only
  # needs to redirect with one param removed from the current query string.
  def clear_filter
    q_params = activity_search_params.to_h

    param_key = params[:param_key]
    param_value = params[:param_value]

    if q_params[param_key].is_a?(Array)
      q_params[param_key].delete(param_value)
      q_params.delete(param_key) if q_params[param_key].empty?
    else
      q_params.delete(param_key)
    end

    q_params.delete("amount_operator") unless q_params["amount"].present?

    redirect_to account_path(@account, q: q_params.presence, tab: "activity", page: params[:page], per_page: params[:per_page])
  end

  def sparkline
    # Short-circuit with 304 Not Modified when the client already has the latest version.
    # We defer the expensive series computation until we know the content is stale.
    if stale?(etag: @account.sparkline_cache_key)
      @sparkline_series = @account.sparkline_series
      render layout: false
    end
  end

  # Loads the icons found for the domain into the account form's icon block,
  # so the rest of the form keeps what the user typed. Nothing is saved here.
  def logo_options
    return redirect_to account_path(@account) unless turbo_frame_request?

    render_logo_options(@account)
  end

  # The same for the form of an account that is not created yet.
  def new_logo_options
    return redirect_to accounts_path unless turbo_frame_request?

    render_logo_options(Current.family.accounts.build)
  end

  # Saves the drag-and-drop order of one account group for the current user.
  def reorder
    if Current.user.update_manual_account_order(params[:group], params[:account_ids])
      head :ok
    else
      head :unprocessable_entity
    end
  end

  def toggle_active
    if @account.active?
      @account.disable!
    elsif @account.disabled?
      @account.enable!
    end
    redirect_to accounts_path
  end

  # Toggles the exclude_from_reports flag on the account and redirects to the
  # account list. The flag controls whether the account's data appears in
  # financial reports, dashboards, and exports.
  def toggle_exclude_from_reports
    @account.update!(exclude_from_reports: !@account.exclude_from_reports?)
    redirect_to accounts_path
  end

  def set_default
    unless @account.eligible_for_transaction_default?
      redirect_to accounts_path, alert: t("accounts.set_default.depository_only")
      return
    end

    Current.user.update!(default_account: @account)
    redirect_to accounts_path
  end

  def remove_default
    Current.user.update!(default_account: nil)
    redirect_to accounts_path
  end

  def destroy
    if @account.linked?
      redirect_to account_path(@account), alert: t("accounts.destroy.cannot_delete_linked")
    else
      begin
        if @account.destroy_later == false
          redirect_to accounts_path, alert: t("accounts.destroy.failed")
        else
          redirect_to accounts_path, notice: t("accounts.destroy.success", type: @account.accountable_type)
        end
      rescue => e
        Rails.logger.error "Failed to schedule account #{@account.id} for deletion: #{e.message}"
        redirect_to accounts_path, alert: t("accounts.destroy.failed")
      end
    end
  end

  def confirm_unlink
  end

  def unlink
    begin
      Account.transaction do
        # Detach holdings from provider links before destroying them
        provider_link_ids = @account.account_providers.pluck(:id)
        if provider_link_ids.any?
          Holding.where(account_provider_id: provider_link_ids).update_all(account_provider_id: nil)
        end

        # Remove provider links (account_providers join table)
        @account.account_providers.reload.destroy_all
      end

      redirect_to accounts_path, notice: t("accounts.unlink.success")
    rescue ActiveRecord::RecordInvalid => e
      redirect_to account_path(@account), alert: t("accounts.unlink.error", error: e.message)
    rescue StandardError => e
      Rails.logger.error "Failed to unlink account #{@account.id}: #{e.message}"
      redirect_to account_path(@account), alert: t("accounts.unlink.error", error: t("accounts.unlink.generic_error"))
    end
  end

  def select_provider
    if @account.linked?
      redirect_to account_path(@account), alert: t("accounts.select_provider.already_linked")
      return
    end

    account_type_name = @account.accountable_type

    # Get all available provider configs dynamically for this account type
    provider_configs = Provider::Factory.connection_configs_for_account_type(
      account_type: account_type_name,
      family: family
    )

    # Build available providers list with paths resolved for this specific account
    # Filter out providers that don't support linking to existing accounts
    @available_providers = provider_configs.filter_map do |config|
      next unless config[:existing_account_path].present?
      {
        name: config[:name],
        key: config[:key],
        description: config[:description],
        path: config[:existing_account_path].call(@account.id)
      }
    end

    if @available_providers.empty?
      redirect_to account_path(@account), alert: t("accounts.select_provider.no_providers")
    end
  end

  private
    # The form may hold a domain or name that is not saved yet.
    def render_logo_options(account)
      account.assign_attributes(params.permit(:institution_domain, :institution_name))
      render partial: "accounts/logo_field", locals: { account: account, candidates: Account::LogoFetcher.new(account).candidates }
    end

    # Built here rather than in the template: assembling a chart payload is
    # domain work, and `show` asks for it exactly once per request, so there
    # is nothing to memoise.
    #
    # The payload runs the schedule, the projection and a balance query from
    # inputs this app does not fully control: `term_months` and `rate_type`
    # arrive from providers, `start_date` and the rate schedule from the form,
    # balances from sync. A raise in any of them costs the chart, not the page:
    # nil is what the component already takes as "no chart", and the account
    # page then renders exactly as it did before the chart existed. Reported,
    # because a loan silently losing its chart is a bug someone has to see.
    def loan_payoff_chart(account, as_of:, period:, projection: nil, extra_projection: nil)
      return nil unless account.accountable.is_a?(Loan)

      Loan::PayoffChart.new(account.loan, as_of: as_of, period: period, projection: projection,
                            extra_projection: extra_projection).payload
    rescue StandardError => e
      Rails.logger.error("Loan payoff chart failed for account #{account.id}: #{e.class} - #{e.message}")
      Sentry.capture_exception(e) { |scope| scope.set_tags(record_type: "Account", record_id: account.id) } if defined?(Sentry)
      nil
    end

    # The Extra repayments tab's form submits `extra_payment[amount]` and
    # `extra_payment[frequency]` over GET. Params of any other shape -- a scalar
    # for the hash, an array for either field -- are no extra rather than an
    # error.
    def loan_extra_repayment
      extra_payment = params[:extra_payment]
      permitted = extra_payment.permit(:amount, :frequency) if extra_payment.is_a?(ActionController::Parameters)
      Loan::ExtraRepayment.new(amount: permitted&.[](:amount), frequency: permitted&.[](:frequency), currency: @account.currency)
    end

    # A plain visit, or a frame request for one of the two frames the chart
    # card sits inside: the account's container frame and the chart card's own
    # chart_details frame. Any other frame is rendered and then discarded.
    def chart_card_requested?
      return true unless turbo_frame_request?

      request.headers["Turbo-Frame"].in?([
        helpers.dom_id(@account, :container),
        helpers.dom_id(@account, :chart_details)
      ])
    end

    def ensure_linked_account
      return if @account.linked?

      redirect_to account_path(@account), alert: t("accounts.unlink.not_linked")
    end

    def family
      Current.family
    end

    def activity_search_params
      q = params.fetch(:q, {}).permit(
        :search, :start_date, :end_date, :amount, :amount_operator,
        categories: [], tags: [], merchants: [], types: [], status: []
      )
      q.delete(:amount_operator) unless q[:amount].present?
      q
    end

    # Shares the "per page" preference with TransactionsController's
    # prev_transaction_page_params so the page size the user picks on either
    # the account activity feed or the global transactions page applies to both.
    def store_per_page!(value)
      Current.session.update!(
        prev_transaction_page_params: Current.session.prev_transaction_page_params.merge("per_page" => value)
      )
    end

    def stored_per_page_default
      Current.session.prev_transaction_page_params["per_page"].presence || 10
    end

    def set_account
      @account = Current.user.accessible_accounts.find(params[:id])
    end

    def set_manageable_account
      @account = Current.user.accessible_accounts.find(params[:id])
      permission = @account.permission_for(Current.user)
      unless permission.in?([ :owner, :full_control ])
        respond_to do |format|
          format.html { redirect_to account_path(@account), alert: t("accounts.not_authorized") }
          format.turbo_stream { stream_redirect_to(account_path(@account), alert: t("accounts.not_authorized")) }
        end
        nil
      end
    end

    # The accounts a provider card on this page may list. A card is admitted
    # by visible_provider_items as soon as ONE of its accounts is accessible,
    # so it must not then render the rest (#3630). Admins see every account.
    def visible_card_accounts(item)
      return item.accounts if Current.user.admin?

      @accessible_account_id_set ||= @accessible_account_ids.to_set
      item.accounts.select { |account| @accessible_account_id_set.include?(account.id) }
    end

    def visible_provider_items(items)
      accessible_ids = @accessible_account_ids.to_a

      items.select do |item|
        next true if Current.user.admin?

        account_ids = item.respond_to?(:accounts) ? item.accounts.map(&:id) : []

        # Ownership shows a member their own connection, importantly including
        # one just created that has not synced any accounts yet. It must not
        # widen what they can see, so an owner is shown the card only while
        # every account on it is already accessible to them.
        if item.respond_to?(:owned_by?) && item.owned_by?(Current.user)
          next true if (account_ids - accessible_ids).empty?
        end

        (account_ids & accessible_ids).any?
      end
    end

    def preload_latest_sync_metadata_for_index!
      syncables = @manual_accounts.to_a

      Current.latest_sync_by_syncable = Sync.latest_by_syncable(syncables)
      Current.latest_completed_sync_by_syncable = Sync.latest_completed_by_syncable(syncables)
      Current.syncing_by_syncable = Sync.syncing_by_syncable(syncables)
    end

    def build_statement_tab_data
      return unless statement_tab_active?

      @statement_coverage = AccountStatement::Coverage.for_year(@account, params[:statement_year])
      @account_statements = @account.account_statements.with_attached_original_file.ordered.to_a
      @statement_reconciliation_statuses = AccountStatement.reconciliation_statuses_for(@account_statements, account: @account)
      permission = @account.permission_for(Current.user)
      @can_manage_statements = AccountStatement.statement_manager?(Current.user) &&
        permission.in?([ :owner, :full_control ])
    end

    def statement_tab_frame_request?
      turbo_frame_request? && request.headers["Turbo-Frame"] == helpers.dom_id(@account, :statements_tab)
    end

    def render_statement_tab_frame
      render partial: "accounts/show/statements_frame", locals: statement_tab_locals, layout: false
    end

    def statement_tab_locals
      {
        account: @account,
        coverage: @statement_coverage,
        statements: @account_statements,
        reconciliation_statuses: @statement_reconciliation_statuses,
        can_manage_statements: @can_manage_statements
      }
    end

    def statement_tab_active?
      @tab == "statements"
    end
end
