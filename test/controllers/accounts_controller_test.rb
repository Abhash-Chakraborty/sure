require "test_helper"

class AccountsControllerTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "should get index" do
    get accounts_url
    assert_response :success
    assert_select "p.ml-auto.privacy-sensitive"
  end

  test "show points an unmatched transaction with a counterpart to the transfer matcher" do
    outflow = create_transaction(account: @account, name: "Hint outflow", amount: 500, date: Date.current)
    create_transaction(account: accounts(:credit_card), name: "Hint inflow", amount: -500, date: Date.current)

    get account_url(@account)

    assert_response :success
    assert_select "a[href='#{new_transaction_transfer_match_path(outflow)}']", text: I18n.t("transactions.transaction.transfer_hint")
  end

  test "show filters account activity to uncategorized transactions" do
    uncategorized = create_transaction(account: @account, name: "Uncategorized Filter Target", category: nil)
    categorized = create_transaction(account: @account, name: "Categorized Filter Decoy", category: categories(:food_and_drink))

    get account_url(@account, q: { categories: [ Category::UNCATEGORIZED_FILTER_VALUE ] })

    assert_response :success
    assert_match uncategorized.name, response.body
    assert_no_match categorized.name, response.body
  end

  test "index delegates whole-row account clicks to the account link" do
    get accounts_url

    assert_response :success
    doc = Nokogiri::HTML::Document.parse(response.body)
    row = doc.at_css("turbo-frame##{dom_id(@account)} [data-controller='clickable-row']")
    account_link = row.at_css("a[data-clickable-row-target='link']")

    assert_equal "click->clickable-row#open", row["data-action"]
    assert_equal account_path(@account), account_link["href"]
  end

  # The default trail ends on "Accounts", which is never a link, so an account's
  # page had no way back to the accounts list.
  test "show links the Accounts crumb back to the accounts list" do
    get account_url(@account)

    assert_response :success
    assert_select "[data-breadcrumbs] a[href=?]", accounts_path, text: I18n.t("breadcrumbs.accounts")
    assert_select "[data-breadcrumbs] > span:last-child", text: @account.name
  end

  test "the accounts list itself stays the unlinked current crumb" do
    get accounts_url

    assert_response :success
    assert_select "[data-breadcrumbs] a[href=?]", accounts_path, count: 0
    assert_select "[data-breadcrumbs] > span:last-child", text: I18n.t("breadcrumbs.accounts")
  end

  test "should get show" do
    get account_url(@account)
    assert_response :success
  end

  test "show renders the balance chart as drag-selectable for a custom date range" do
    get account_url(@account)

    assert_response :success
    assert_select "#lineChart[data-time-series-chart-selectable-value='true']"
  end

  test "show honors a custom start_date/end_date range" do
    start_date = 15.days.ago.to_date
    end_date = Date.current

    get account_url(@account), params: { start_date: start_date.to_s, end_date: end_date.to_s }

    assert_response :success
    # If the params were ignored, the user's default preset would render as the
    # checked option instead of the custom row.
    assert_select "a[role='menuitemradio'][aria-checked='true'][href*='period=']", count: 0
    assert_select "a[role='menuitemradio'][aria-checked='true'][href*='start_date=']", count: 1
  end

  test "show filter menu offers the same filters as transactions except the account tab" do
    get account_url(@account)

    assert_response :success
    assert_select "#transaction-filters-menu button[data-id=?]", "account_filter", count: 0
    assert_select "#transaction-filters-menu button[data-id=?]", "category_filter", count: 1
    assert_select "#transaction-filters-menu button[data-id=?]", "tag_filter", count: 1
    assert_select "#transaction-filters-menu button[data-id=?]", "merchant_filter", count: 1
    assert_select "#transaction-filters-menu button[data-id=?]", "type_filter", count: 1
  end

  test "show filters activity by category and excludes non-Transaction entries" do
    categorized = create_transaction(name: "Categorized", amount: 50, account: @account, category: categories(:food_and_drink))
    uncategorized = create_transaction(name: "Uncategorized", amount: 60, account: @account)
    valuation = @account.entries.create!(
      name: "Balance update", date: 1.day.ago.to_date, amount: 1000, currency: "USD", entryable: Valuation.new
    )

    get account_url(@account), params: { q: { categories: [ "Food & Drink" ] } }

    assert_response :success
    assert_select "##{dom_id(categorized)}"
    assert_select "##{dom_id(uncategorized)}", count: 0
    assert_select "##{dom_id(valuation)}", count: 0
  end

  test "show renders a badge for each active filter" do
    get account_url(@account), params: { q: { categories: [ "Food & Drink" ], search: "grocery" } }

    assert_response :success
    assert_select "#account-activity-filters li", count: 2
  end

  test "show renders badge delete links that preserve the other active filters" do
    get account_url(@account), params: { q: { categories: [ "Food & Drink" ], search: "grocery" } }

    assert_response :success
    doc = Nokogiri::HTML::Document.parse(response.body)
    badge = doc.css("#account-activity-filters li").find { |li| li.text.include?("Food & Drink") }
    form = badge&.at_css("form")

    assert_not_nil form, "expected the category badge to render a delete form"
    action_uri = URI.parse(form["action"])
    action_params = Rack::Utils.parse_nested_query(action_uri.query)

    # Regression: the badge's delete link must carry the *other* active
    # filters along (like clear_filter_transactions_path does via
    # request.query_parameters), or clearing one filter wipes them all.
    assert_equal "grocery", action_params.dig("q", "search"),
      "clearing the category badge must not drop the search filter from the delete link"
  end

  test "clear_filter removes only the targeted filter value and preserves the rest" do
    delete clear_filter_account_url(@account), params: {
      q: { categories: [ "Food & Drink" ], search: "grocery" },
      param_key: "categories",
      param_value: "Food & Drink"
    }

    assert_redirected_to account_url(@account, q: { search: "grocery" }, tab: "activity", page: nil, per_page: nil)
  end

  test "clear_filter drops the amount_operator once amount is cleared" do
    delete clear_filter_account_url(@account), params: {
      q: { amount: "50", amount_operator: "equal" },
      param_key: "amount",
      param_value: "50"
    }

    assert_redirected_to account_url(@account, q: nil, tab: "activity", page: nil, per_page: nil)
  end

  test "show renders without missing translations" do
    get account_url(@account)

    assert_response :success
    assert_empty response.body.scan(/translation missing: [\w.]+/).uniq
  end

  test "sync all syncs the family" do
    Family.any_instance.expects(:sync_later).once

    post sync_all_accounts_url

    assert_redirected_to accounts_url
  end

  test "show avoids N+1 transfer queries across paginated entries" do
    queries = capture_sql_queries { get account_url(@account) }
    assert_response :success

    # Per-row transfer lookups (N+1 pattern) hit transfers with a single id
    # Preloading batches them into IN(...) — assert no single-id lookups remain
    per_row_transfer = queries.count { |q|
      q.match?(/FROM "transfers".*WHERE.*"(inflow|outflow)_transaction_id"/) &&
        !q.include?(" IN (")
    }
    assert_equal 0, per_row_transfer, "N+1 per-row transfer queries detected (#{per_row_transfer})"
  end

  test "show delegates whole-row trade clicks to the drawer link" do
    investment_account = accounts(:investment)
    entry = entries(:trade)

    get account_url(investment_account)

    assert_response :success
    doc = Nokogiri::HTML::Document.parse(response.body)
    row = doc.at_css("turbo-frame##{dom_id(entry.entryable)} [data-controller='clickable-row']")
    drawer_link = row.at_css("a[data-clickable-row-target='link']")

    assert_equal "click->clickable-row#open", row["data-action"]
    assert_equal entry_path(entry), drawer_link["href"]
  end

  test "show avoids N+1 split-parent queries across paginated entries" do
    queries = capture_sql_queries { get account_url(@account) }
    assert_response :success

    # Per-row child-entry existence checks (N+1) hit entries with a single parent_entry_id
    # @split_parent_entry_ids preloads this in one batch IN query
    per_row_split = queries.count { |q|
      q.match?(/FROM "entries".*WHERE.*"parent_entry_id"/) && !q.include?(" IN (")
    }
    assert_equal 0, per_row_split, "N+1 per-row split-parent queries detected (#{per_row_split})"
  end

  test "show groups split transactions into a single split-group row when grouping is enabled" do
    @user.update!(preferences: { "show_split_grouped" => true })
    entry = create_transaction(name: "Grocery Store", amount: 100, account: @account)
    entry.split!([
      { name: "Food", amount: 60 },
      { name: "Household", amount: 40 }
    ])

    get account_url(@account)

    assert_response :success
    assert_select ".split-group", count: 1
    assert_select ".split-group" do
      assert_select "p", text: "Food", count: 0
    end
  end

  test "show renders split children as flat rows when grouping is disabled" do
    @user.update!(preferences: { "show_split_grouped" => false })
    entry = create_transaction(name: "Grocery Store", amount: 100, account: @account)
    entry.split!([
      { name: "Food", amount: 60 },
      { name: "Household", amount: 40 }
    ])

    get account_url(@account)

    assert_response :success
    assert_select ".split-group", count: 0
  end

  test "show avoids N+1 queries when loading split parents for grouped display" do
    @user.update!(preferences: { "show_split_grouped" => true })
    3.times do |i|
      entry = create_transaction(name: "Grocery Store #{i}", amount: 100, account: @account)
      entry.split!([
        { name: "Food", amount: 60 },
        { name: "Household", amount: 40 }
      ])
    end

    queries = capture_sql_queries { get account_url(@account) }
    assert_response :success

    # @split_parents loads all referenced split-parent entries in a single
    # `WHERE "entries"."id" IN (...)` query — a per-row `"id" = $1` lookup
    # would indicate the batching regressed into N+1.
    per_row_split_parent = queries.count { |q|
      q.match?(/FROM "entries".*WHERE.*"entries"\."id" = \$?\d+/) && !q.include?(" IN (")
    }
    assert_equal 0, per_row_split_parent, "N+1 per-row split-parent lookups detected (#{per_row_split_parent})"
  end

  test "show lazily loads statement tab data unless statements tab is active" do
    AccountStatement::Coverage.expects(:for_year).never
    AccountStatement.expects(:reconciliation_statuses_for).never

    get account_url(@account)

    assert_response :success
    assert_select "select[name='statement_year']", count: 0
    statements_path = account_path(@account, tab: "statements")
    assert_select "turbo-frame[src='#{statements_path}']"
  end

  test "statements tab links escape turbo frame for full-page navigation" do
    # Upload a statement to ensure table rows render
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      file: uploaded_file(
        filename: "test.pdf",
        content_type: "application/pdf",
        content: "%PDF-1.4 test content"
      ),
      account: @account
    )


    get account_url(@account, tab: "statements")

    assert_response :success

    # Inbox link escapes frame
    assert_select "a[href='#{account_statements_path}'][data-turbo-frame='_top']"

    # Statement filename link escapes frame
    assert_select "a[data-turbo-frame='_top']", text: statement.filename

    # Eye/view icon escapes frame and opens in new tab
    assert_select "a[target='_blank'][data-turbo-frame='_top'][aria-label='#{I18n.t("account_statements.table.view")}']"

    # Edit icon escapes frame
    assert_select "a[href='#{account_statement_path(statement)}'][data-turbo-frame='_top'][aria-label='#{I18n.t("account_statements.table.edit")}']"

    # Unlink button escapes frame
    assert_select "form[action='#{unlink_account_statement_path(statement)}'][data-turbo-frame='_top'] button"
  end

  test "statements tab shows coverage and upload for statement managers with account write access" do
    get account_url(@account, tab: "statements")

    assert_response :success
    assert_select "input[type=file][accept='.pdf,.csv,.xlsx']"
    assert_select "select[name='statement_year']"
    assert_select "p", text: I18n.l(Date.current.prev_month.beginning_of_month, format: "%b %Y")
  end

  test "statements tab lazy frame returns matching frame content" do
    frame_id = dom_id(@account, :statements_tab)

    get account_url(@account, tab: "statements"), headers: { "Turbo-Frame" => frame_id }

    assert_response :success
    assert_select "turbo-frame##{frame_id}", count: 1
    assert_select "select[name='statement_year']"
    assert_select "turbo-frame##{dom_id(@account, :container)}", count: 0
  end

  test "statements tab filters historical coverage by year" do
    account = Account.create!(
      family: @user.family,
      owner: @user,
      name: "Historical Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    statement = AccountStatement.create_from_upload!(
      family: @user.family,
      account: account,
      file: uploaded_file(filename: "historical.csv", content_type: "text/csv")
    )
    statement.update!(period_start_on: Date.new(2024, 2, 1), period_end_on: Date.new(2024, 2, 29))

    travel_to Date.new(2026, 5, 6) do
      get account_url(account, tab: "statements")

      assert_response :success
      assert_select "select[name='statement_year'] option[selected='selected']", text: "2026"
      assert_select "p", text: "May 2026"
      assert_select "p", text: "Not expected"

      get account_url(account, tab: "statements", statement_year: 2024)

      assert_response :success
      assert_select "select[name='statement_year'] option[selected='selected']", text: "2024"
      assert_select "p", text: "Jan 2024"
      assert_select "p", text: "Feb 2024"
      assert_select "p", text: "Covered"
      assert_select "p", text: "Missing"
      assert_select "p", text: "Not expected"
    end
  end

  test "statements tab hides upload for read only account access" do
    sign_in users(:family_member)

    get account_url(accounts(:credit_card), tab: "statements")

    assert_response :success
    assert_select "input[type=file]", count: 0
  end

  test "credit card page offers an overview tab" do
    sign_in users(:family_admin)

    get account_url(accounts(:credit_card))

    assert_response :success
    assert_select "[role=tab][data-id=overview]"
    assert_select "[role=tabpanel][data-id=overview]"
  end

  test "credit card overview renders the statement cycle" do
    sign_in users(:family_admin)
    card = accounts(:credit_card).credit_card
    card.update!(statement_close_day: 25, due_day: 5, minimum_payment: 25)
    accounts(:credit_card).entries.create!(
      name: "Cycle charge",
      date: Date.current.beginning_of_month + 9.days,
      amount: 100,
      currency: "USD",
      entryable: Transaction.new
    )

    get account_url(accounts(:credit_card), tab: "overview")

    assert_response :success
    assert_match I18n.t("credit_cards.tabs.overview.statement_balance"), response.body
  end

  test "credit card overview hides the APR card when APR is blank" do
    sign_in users(:family_admin)
    accounts(:credit_card).credit_card.update!(statement_close_day: 25, due_day: 5, apr: nil, minimum_payment: nil)

    get account_url(accounts(:credit_card), tab: "overview")

    assert_response :success
    assert_select "h4", text: I18n.t("credit_cards.tabs.overview.annual_percentage_rate"), count: 0
    assert_select "[data-testid='credit-card-summary-grid'][class*='sm:grid-cols-2']", count: 1
    assert_select "[data-testid='credit-card-summary-grid'][class*='@3xl:grid-cols-3']", count: 0
  end

  test "credit card overview shows the APR card when APR is present" do
    sign_in users(:family_admin)
    accounts(:credit_card).credit_card.update!(statement_close_day: 25, due_day: 5, apr: 18.99, minimum_payment: nil)

    get account_url(accounts(:credit_card), tab: "overview")

    assert_response :success
    assert_select "h4", text: I18n.t("credit_cards.tabs.overview.annual_percentage_rate"), count: 1
    assert_select "[data-testid='credit-card-summary-grid'][class*='sm:grid-cols-2']", count: 1
    assert_select "[data-testid='credit-card-summary-grid'][class*='@3xl:grid-cols-3']", count: 1
  end

  test "credit card overview shows the estimated monthly interest for the APR" do
    sign_in users(:family_admin)
    account = accounts(:credit_card)
    account.credit_card.update!(statement_close_day: 10, due_day: 26, apr: 12, minimum_payment: nil)

    travel_to Date.new(2026, 10, 16) do
      account.entries.create!(
        name: "Cycle charge", date: Date.new(2026, 9, 20), amount: 1200, currency: "USD",
        entryable: Transaction.new
      )

      get account_url(account, tab: "overview")

      assert_response :success
      assert_match I18n.t("credit_cards.tabs.overview.estimated_interest_label"), response.body
      assert_match I18n.t("credit_cards.tabs.overview.per_month", amount: Money.new(12, "USD").format), response.body
      assert_match I18n.t("credit_cards.tabs.overview.monthly_rate_label"), response.body
      assert_match I18n.t("credit_cards.tabs.overview.balance_carried_label"), response.body
      assert_match "1.000%", response.body
    end
  end

  test "credit card overview hides the minimum warning when minimum payment is blank" do
    sign_in users(:family_admin)
    account = accounts(:credit_card)
    account.credit_card.update!(statement_close_day: 10, due_day: 26, minimum_payment: nil)

    travel_to Date.new(2026, 10, 16) do
      account.entries.create!(
        name: "Cycle charge", date: Date.new(2026, 9, 20), amount: 100, currency: "USD",
        entryable: Transaction.new
      )

      get account_url(account, tab: "overview")

      assert_response :success
      assert_no_match "This statement came to", response.body
    end
  end

  test "credit card overview shows the remaining amount and partial status" do
    sign_in users(:family_admin)
    account = accounts(:credit_card)
    account.credit_card.update!(statement_close_day: 10, due_day: 26)

    travel_to Date.new(2026, 10, 16) do
      account.entries.create!(
        name: "Cycle charge", date: Date.new(2026, 9, 20), amount: 100, currency: "USD",
        entryable: Transaction.new
      )
      account.entries.create!(
        name: "Card payment", date: Date.new(2026, 10, 12), amount: -40, currency: "USD",
        entryable: Transaction.new
      )

      get account_url(account, tab: "overview")

      assert_response :success
      assert_match I18n.t("credit_cards.tabs.overview.remaining_due", amount: Money.new(60, "USD").format), response.body
      assert_match I18n.t("credit_cards.tabs.overview.status_partial"), response.body
    end
  end

  test "credit card overview shows the cycle breakdown and next close" do
    sign_in users(:family_admin)
    account = accounts(:credit_card)
    account.credit_card.update!(statement_close_day: 10, due_day: 26)

    travel_to Date.new(2026, 10, 16) do
      account.entries.create!(
        name: "Cycle charge", date: Date.new(2026, 10, 12), amount: 100, currency: "USD",
        entryable: Transaction.new
      )
      account.entries.create!(
        name: "Card payment", date: Date.new(2026, 10, 14), amount: -40, currency: "USD",
        entryable: Transaction.new
      )

      get account_url(account, tab: "overview")

      assert_response :success
      assert_match I18n.t("credit_cards.tabs.overview.charges"), response.body
      assert_match I18n.t("credit_cards.tabs.overview.payments_credits"), response.body
      assert_match Money.new(100, "USD").format, response.body
      assert_match Money.new(40, "USD").format, response.body
      assert_match I18n.t("credit_cards.tabs.overview.closes_on", date: I18n.l(Date.new(2026, 11, 10), format: :long)), response.body
    end
  end

  test "credit card overview shows the next open scheduled card payment" do
    sign_in users(:family_admin)
    account = accounts(:credit_card)
    account.credit_card.update!(statement_close_day: 10, due_day: 26)

    travel_to Date.new(2026, 10, 16) do
      series = account.inbound_recurring_transfers.create!(
        family: account.family,
        account: accounts(:depository),
        name: "Card payment",
        amount: 40,
        currency: "USD",
        expected_day_of_month: 24,
        last_occurrence_date: Date.new(2026, 9, 24),
        next_expected_date: Date.new(2026, 10, 24),
        manual: true
      )
      open_due = series.recurring_occurrences.open_status.minimum(:due_on)

      get account_url(account, tab: "overview")

      assert_response :success
      assert_match I18n.t(
        "credit_cards.tabs.overview.scheduled_payment",
        amount: Money.new(40, "USD").format,
        date: I18n.l(open_due, format: :long)
      ), response.body
    end
  end

  test "credit card overview hides a scheduled payment from a member without its source" do
    sign_in users(:family_member)
    account = accounts(:credit_card)
    account.credit_card.update!(statement_close_day: 10, due_day: 26)
    account.inbound_recurring_transfers.create!(
      family: account.family,
      account: accounts(:investment),
      name: "Card payment",
      amount: 40,
      currency: "USD",
      expected_day_of_month: 24,
      last_occurrence_date: 2.months.ago.to_date,
      next_expected_date: 1.month.from_now.to_date,
      bill_type: "transfer",
      manual: true
    )

    get account_url(account, tab: "overview")

    assert_response :success
    assert_no_match "Scheduled payment", response.body
  end

  test "credit card overview highlights an overdue statement" do
    sign_in users(:family_admin)
    account = accounts(:credit_card)
    account.credit_card.update!(statement_close_day: 5, due_day: 21)

    travel_to Date.new(2026, 10, 30) do
      account.entries.create!(
        name: "Cycle charge", date: Date.new(2026, 9, 20), amount: 552, currency: "USD",
        entryable: Transaction.new
      )

      get account_url(account, tab: "overview")

      assert_response :success
      assert_select "span.text-destructive", text: I18n.t("credit_cards.due.overdue", count: 9)
    end
  end

  test "credit card overview shows the payment due this month for an early close day" do
    sign_in users(:family_admin)
    accounts(:credit_card).credit_card.update!(statement_close_day: 10, due_day: 26)

    # A card closing on the 10th and due on the 26th, read on the 16th. The
    # bill due is the statement that closed on the 10th, which falls on the 26th
    # of THIS month -- not the 26th of next, which is the statement still
    # building and not yet owed.
    travel_to Date.new(2026, 10, 16) do
      get account_url(accounts(:credit_card), tab: "overview")

      assert_response :success
      assert_match I18n.l(Date.new(2026, 10, 26), format: :long), response.body
      assert_match I18n.t("credit_cards.due.in_days", count: 10), response.body
    end
  end

  test "credit card overview reads a negative since-statement balance as a credit" do
    sign_in users(:family_admin)
    account = accounts(:credit_card)
    account.credit_card.update!(statement_close_day: 10, due_day: 26)

    travel_to Date.new(2026, 10, 16) do
      account.entries.create!(
        name: "Cycle charge", date: Date.new(2026, 9, 20), amount: 100, currency: "USD",
        entryable: Transaction.new
      )
      account.entries.create!(
        name: "Payment after the close", date: Date.new(2026, 10, 12), amount: -250, currency: "USD",
        entryable: Transaction.new
      )

      get account_url(account, tab: "overview")

      assert_response :success
      assert_match I18n.t("credit_cards.tabs.overview.credit_toward_next"), response.body
    end
  end

  test "credit card overview shows the credit label when a credit outlives the due date" do
    sign_in users(:family_admin)
    account = accounts(:credit_card)
    account.credit_card.update!(statement_close_day: 10, due_day: 26)

    # Read after the 26th: the due date has rolled to the statement still
    # building, and the cardholder has paid down more than that statement has
    # accrued. The credit is the fact worth stating; a due date here would
    # promise a payment the credit may cancel.
    travel_to Date.new(2026, 10, 30) do
      account.entries.create!(
        name: "Cycle charge", date: Date.new(2026, 9, 20), amount: 100, currency: "USD",
        entryable: Transaction.new
      )
      account.entries.create!(
        name: "Payment after the close", date: Date.new(2026, 10, 12), amount: -250, currency: "USD",
        entryable: Transaction.new
      )

      get account_url(account, tab: "overview")

      assert_response :success
      assert_match I18n.t("credit_cards.tabs.overview.credit_toward_next"), response.body
      assert_no_match I18n.l(Date.new(2026, 11, 26), format: :long), response.body
    end
  end

  test "credit card overview asks for a cycle when none is set" do
    sign_in users(:family_admin)

    get account_url(accounts(:credit_card), tab: "overview")

    assert_response :success
    assert_match I18n.t("credit_cards.tabs.overview.no_cycle_title"), response.body
  end

  test "account activity marks trade amounts as privacy-sensitive" do
    trade_entry = entries(:trade)
    expected_amount = ApplicationController.helpers.format_money(-trade_entry.amount_money)

    get account_url(accounts(:investment))

    assert_response :success
    assert_select "turbo-frame##{dom_id(trade_entry)} p.privacy-sensitive", text: expected_amount, count: 1
  end

  test "account activity keeps excluded entries visible so they can be restored" do
    trade_entry = entries(:trade)
    trade_entry.update!(excluded: true)

    get account_url(accounts(:investment))

    assert_response :success
    assert_select "turbo-frame##{dom_id(trade_entry)}"
  end

  test "renders investment account with gains chart view" do
    get account_url(accounts(:investment), chart_view: "gains")

    assert_response :success
    assert_select "option[value=gains][selected]"
    assert_select "p", text: I18n.t("UI.account.chart.title.total_gains")
  end

  # The chart and the Schedule tab's forecast card read one projection. The
  # chart used to build one and the Schedule partial a second, for the same
  # date, on every render of a loan's page.
  test "a loan account page builds its payoff projection once for the chart and the Schedule tab" do
    loan_account = accounts(:loan)
    projection = loan_account.loan.payoff_projection(as_of: Date.current)
    Loan.any_instance.expects(:payoff_projection).once.returns(projection)

    get account_url(loan_account)

    assert_response :success
    assert_includes response.body, I18n.t("loans.tabs.schedule.forecasted_payoff_date")
  end

  test "remembers selected per_page across account navigation" do
    other_account = accounts(:credit_card)

    get account_url(@account, per_page: 50)
    assert_response :success
    assert_select "select[name='per_page'] option[value='50'][selected]"

    get account_url(other_account)
    assert_response :success
    assert_select "select[name='per_page'] option[value='50'][selected]"
  end

  test "shares remembered per_page with the global transactions page" do
    get transactions_url(per_page: 100)
    assert_response :success

    get account_url(@account)
    assert_response :success
    assert_select "select[name='per_page'] option[value='100'][selected]"
  end

  test "shares account per_page preference with the global transactions page" do
    get account_url(@account, per_page: 50)
    assert_response :success

    get transactions_url
    assert_response :redirect
    follow_redirect!
    assert_response :success
    assert_select "select[name='per_page'] option[value='50'][selected]"
  end

  test "falls back to default per_page when nothing was stored yet" do
    get account_url(@account)
    assert_response :success
    assert_select "select[name='per_page'] option[value='10'][selected]"
  end

  test "activity pagination keeps activity tab when loaded from holdings tab" do
    investment = accounts(:investment)

    11.times do |i|
      Entry.create!(
        account: investment,
        name: "Test investment activity #{i}",
        date: Date.current - i.days,
        amount: 10 + i,
        currency: investment.currency,
        entryable: Transaction.new
      )
    end

    get account_url(investment, tab: "holdings")

    assert_response :success
    assert_select "a[href*='page=2'][href*='tab=activity']"
    assert_select "a[href*='page=2'][href*='tab=holdings']", count: 0
  end

  test "account activity constrains long category labels before the amount on wide screens" do
    category = categories(:food_and_drink)
    category.update!(name: "Super Long Category Name That Should Stop Before The Amount On Wide Screens Too")

    entry = @account.entries.create!(
      name: "Wide category verification",
      date: Date.current,
      amount: 187.65,
      currency: @account.currency,
      entryable: Transaction.new(category: category)
    )

    get account_url(@account, tab: "activity")

    assert_response :success
    assert_select "##{dom_id(entry.entryable, "category_menu_desktop")}"
    assert_select "##{dom_id(entry.entryable, "category_menu_desktop")}.min-w-0"
    assert_select "##{dom_id(entry.entryable, "category_menu_desktop")}.overflow-hidden"
    assert_select "##{dom_id(entry.entryable, "category_menu_desktop")} button.block"
    assert_select "##{dom_id(entry.entryable, "category_menu_desktop")} button.w-full"
    assert_select "##{dom_id(entry.entryable, "category_menu_desktop")} button.overflow-hidden"
    assert_select "##{dom_id(entry.entryable, "category_menu_desktop")} [data-testid='category-name']"
    assert_select "div.hidden.md\\:flex.min-w-0"
  end

  test "should sync account" do
    post sync_account_url(@account)
    assert_redirected_to account_url(@account)
  end

  test "should get sparkline" do
    get sparkline_account_url(@account)
    assert_response :success
  end

  test "sparkline stays fresh when another account syncs" do
    get sparkline_account_url(@account)
    etag = response.headers["ETag"]

    @account.family.touch(:latest_sync_completed_at)
    get sparkline_account_url(@account), headers: { "If-None-Match" => etag }

    assert_response :not_modified
  end

  test "sparkline is re-rendered when the account's balances change" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    get sparkline_account_url(@account)
    etag = response.headers["ETag"]
    before = response.body

    travel 1.minute do
      @account.balances.create!(date: 3.days.ago.to_date, balance: 1234, start_cash_balance: 1234, currency: @account.currency)
      get sparkline_account_url(@account), headers: { "If-None-Match" => etag }
    end

    assert_response :success
    assert_not_equal before, response.body
  end

  test "sparkline is re-rendered after the account's own sync completes" do
    get sparkline_account_url(@account)
    etag = response.headers["ETag"]

    travel 1.minute do
      @account.syncs.create!(status: "completed", completed_at: Time.current)
      get sparkline_account_url(@account), headers: { "If-None-Match" => etag }
    end

    assert_response :success
  end

  test "an investment sparkline is re-rendered after any family sync" do
    investment = accounts(:investment)
    get sparkline_account_url(investment)
    etag = response.headers["ETag"]

    travel 1.minute do
      investment.family.touch(:latest_sync_completed_at)
      get sparkline_account_url(investment), headers: { "If-None-Match" => etag }
    end

    assert_response :success
  end

  test "sparkline renders an empty series without a trend" do
    empty_series = Series.new(
      start_date: 1.day.ago.to_date,
      end_date: Date.current,
      interval: "1 day",
      values: []
    )
    Account.any_instance.expects(:sparkline_series).returns(empty_series)

    get sparkline_account_url(@account)

    assert_response :success
    assert_select "p.font-mono", count: 0
  end

  test "destroys account" do
    delete account_url(@account)
    assert_redirected_to accounts_path
    assert_enqueued_with job: DestroyJob
    assert_equal "Depository account scheduled for deletion", flash[:notice]
  end

  test "destroy reports failure and keeps the account listed when the enqueue raises" do
    DestroyJob.queue_adapter.stubs(:enqueue).raises(RedisClient::CannotConnectError, "Connection refused")

    delete account_url(@account)

    assert_redirected_to accounts_path
    assert_equal I18n.t("accounts.destroy.failed"), flash[:alert]
    assert_equal "active", @account.reload.status

    get accounts_url
    assert_select "turbo-frame##{dom_id(@account)}"
  end

  test "destroy reports failure when the enqueue is rejected" do
    DestroyJob.queue_adapter.stubs(:enqueue).raises(ActiveJob::EnqueueError, "rejected")

    delete account_url(@account)

    assert_redirected_to accounts_path
    assert_equal I18n.t("accounts.destroy.failed"), flash[:alert]
    assert_nil flash[:notice]
    assert_equal "active", @account.reload.status
  end

  # The second request of a double submit finds the account already pending
  # deletion. It reports failure rather than erroring, enqueues nothing more,
  # and leaves the first request's mark in place.
  test "a second destroy of an account pending deletion reports failure" do
    delete account_url(@account)
    assert_equal "pending_deletion", @account.reload.status

    assert_no_enqueued_jobs(only: DestroyJob) do
      delete account_url(@account)
    end

    assert_redirected_to accounts_path
    assert_equal I18n.t("accounts.destroy.failed"), flash[:alert]
    assert_equal "pending_deletion", @account.reload.status
  end

  test "syncing unlinked account calls account sync_later" do
    Account.any_instance.expects(:syncing?).returns(false)
    Account.any_instance.expects(:sync_later).once

    post sync_account_url(@account)
    assert_redirected_to account_url(@account)
  end

  test "redirects when confirming unlink for unlinked account" do
    get confirm_unlink_account_url(@account)
    assert_redirected_to account_url(@account)
    assert_equal "Account is not linked to a provider", flash[:alert]
  end

  test "redirects when unlinking unlinked account" do
    delete unlink_account_url(@account)
    assert_redirected_to account_url(@account)
    assert_equal "Account is not linked to a provider", flash[:alert]
  end

  test "disabling an account keeps it visible on index" do
    @account.disable!

    get accounts_path

    assert_response :success
    assert_includes @response.body, @account.name
  end

  test "toggle_active disables and re-enables an account" do
    patch toggle_active_account_url(@account)
    assert_redirected_to accounts_path
    @account.reload
    assert @account.disabled?

    patch toggle_active_account_url(@account)
    assert_redirected_to accounts_path
    @account.reload
    assert @account.active?
  end

  test "toggle_exclude_from_reports toggles the flag on an account" do
    assert_not @account.exclude_from_reports?

    patch toggle_exclude_from_reports_account_url(@account)
    assert_redirected_to accounts_path
    @account.reload
    assert @account.exclude_from_reports?

    patch toggle_exclude_from_reports_account_url(@account)
    assert_redirected_to accounts_path
    @account.reload
    assert_not @account.exclude_from_reports?
  end

  test "toggle_exclude_from_reports requires write permission" do
    sign_in users(:family_member)

    patch toggle_exclude_from_reports_account_url(accounts(:credit_card))
    assert_redirected_to account_url(accounts(:credit_card))
  end

  test "logo_options shows the icons found and Brandfetch inside the logo frame without saving" do
    Setting.stubs(:brand_fetch_client_id).returns("test-client-id")
    @account.update!(institution_domain: "krungsri.com")
    @account.logo.attach(io: file_fixture("square-placeholder.png").open, filename: "krungsri.com.png",
                         metadata: { "logo_source" => "yandex", "logo_key" => "yandex", "logo_auto" => true })
    icons = [ logo_icon("appstore:123", "appstore", 512, name: "krungsri"),
              logo_icon("yandex", "yandex", 120, body: file_fixture("square-placeholder.png").binread) ]
    Account::LogoFetcher.any_instance.stubs(:candidates).returns(icons)

    get logo_options_account_url(@account), headers: { "Turbo-Frame" => dom_id(@account, :logo_field) }

    assert_response :success
    assert_select "turbo-frame##{dom_id(@account, :logo_field)}"
    assert_select "button[type=button][data-account-logo-picker-choice-param='appstore:123'][title=krungsri]"
    assert_select "button[type=button][data-account-logo-picker-choice-param=brandfetch]"
    assert_select "button[type=button][data-account-logo-picker-choice-param]", 2, "the current icon only resets the choice"
    assert_select "button[type=submit]:not([form])", 0, "choosing an icon saves nothing"
    assert_select "img[src^='data:image/png;base64,']", 2
  end

  test "logo_options searches the domain typed in the form without saving it" do
    @account.update!(institution_domain: "tbank.ru")
    Account::LogoFetcher.expects(:new).with { |account| account.institution_domain == "krungsri.com" && account.institution_name == "Krungsri" }
      .returns(stub(candidates: []))

    get logo_options_account_url(@account), params: { institution_domain: "https://www.krungsri.com/", institution_name: "Krungsri" },
                                            headers: { "Turbo-Frame" => dom_id(@account, :logo_field) }

    assert_response :success
    assert_equal "tbank.ru", @account.reload.institution_domain
  end

  test "logo_options for a new account searches the typed domain" do
    Account::LogoFetcher.expects(:new).with { |account| account.new_record? && account.institution_domain == "krungsri.com" }
      .returns(stub(candidates: []))

    get logo_options_accounts_url, params: { institution_domain: "krungsri.com", institution_name: "Krungsri" },
                                   headers: { "Turbo-Frame" => "logo_field_account" }

    assert_response :success
    assert_select "turbo-frame#logo_field_account"
  end

  test "logo_options keeps an icon selectable when its source now serves a different image" do
    @account.update!(institution_domain: "krungsri.com")
    @account.logo.attach(io: file_fixture("square-placeholder.png").open, filename: "krungsri.com.png",
                         metadata: { "logo_source" => "yandex", "logo_key" => "yandex", "logo_auto" => true })
    Account::LogoFetcher.any_instance.stubs(:candidates).returns([ logo_icon("yandex", "yandex", 120) ])

    get logo_options_account_url(@account), headers: { "Turbo-Frame" => dom_id(@account, :logo_field) }

    assert_select "button[data-account-logo-picker-choice-param=yandex]"
  end

  test "logo_options outside the frame goes to the account" do
    get logo_options_account_url(@account)

    assert_redirected_to account_url(@account)
  end

  test "logo_options requires write permission" do
    sign_in users(:family_member)

    get logo_options_account_url(accounts(:credit_card))
    assert_redirected_to account_url(accounts(:credit_card))
  end

  test "select_provider redirects when no provider is configured" do
    get select_provider_account_url(@account)
    assert_redirected_to account_url(@account)
    assert_equal I18n.t("accounts.select_provider.no_providers"), flash[:alert]
  end

  test "set_default sets user default account" do
    patch set_default_account_url(@account)
    assert_redirected_to accounts_path
    @user.reload
    assert_equal @account.id, @user.default_account_id
  end

  test "set_default rejects ineligible account type" do
    investment = accounts(:investment)

    patch set_default_account_url(investment)
    assert_redirected_to accounts_path
    assert_equal I18n.t("accounts.set_default.depository_only"), flash[:alert]

    @user.reload
    assert_not_equal investment.id, @user.default_account_id
  end

  test "remove_default clears user default account" do
    @user.update!(default_account: @account)

    patch remove_default_account_url(@account)
    assert_redirected_to accounts_path

    @user.reload
    assert_nil @user.default_account_id
  end

  # Regression for #2516: the account sidebar fragment cache renders DS::* view
  # components, which Rails' ERB dependency tracker mis-parses as a bogus "Ds/D"
  # template dependency. With automatic digesting enabled that logged
  # "Couldn't find template for digesting: Ds/D" on every cache miss. The
  # fragment is manually versioned and opts out of digesting via skip_digest.
  test "sidebar fragment cache does not log a bogus template digest error" do
    log = StringIO.new
    logger = ActiveSupport::Logger.new(log)

    original_perform_caching = ActionController::Base.perform_caching
    original_view_logger = ActionView::Base.logger
    original_rails_logger = Rails.logger

    ActionController::Base.perform_caching = true
    ActionView::Base.logger = logger
    Rails.logger = logger

    get accounts_path
    assert_response :success
    assert_no_match(/Couldn't find template for digesting/, log.string)
  ensure
    ActionController::Base.perform_caching = original_perform_caching
    ActionView::Base.logger = original_view_logger
    Rails.logger = original_rails_logger
  end

  test "reorder saves the manual order of one account group" do
    # Same shape as the sidebar's sortable-list: group in the URL, ids in the body.
    patch reorder_accounts_url(group: "depository"), params: { account_ids: [ accounts(:connected).id, @account.id ] }, as: :json

    assert_response :success
    assert_equal [ accounts(:connected).id, @account.id ], @user.reload.manual_account_order["depository"]
  end

  test "reorder drops accounts from another family" do
    foreign = families(:empty).accounts.create!(name: "Foreign", currency: "USD", balance: 0, accountable: Depository.new, owner: users(:empty))

    patch reorder_accounts_url, params: { group: "depository", account_ids: [ foreign.id, @account.id ] }, as: :json

    assert_response :success
    assert_equal [ @account.id ], @user.reload.manual_account_order["depository"]
  end

  test "reorder rejects an unknown group" do
    patch reorder_accounts_url, params: { group: "not_a_type", account_ids: [ @account.id ] }, as: :json

    assert_response :unprocessable_entity
    assert_nil @user.reload.manual_account_order["not_a_type"]
  end

  test "sidebar shows drag handles only with the manual account order" do
    get account_url(@account)
    assert_select "[data-controller~='sortable-list']", count: 0

    @user.update!(default_account_order: "manual")
    get account_url(@account)
    assert_select "[data-controller~='sortable-list'][data-sortable-list-url-value=?]", reorder_accounts_path(group: "depository")
    assert_select "[data-sortable-list-target='item'][data-sortable-list-id=?]", @account.id
  end

  private
    def logo_icon(key, source, size, name: nil, body: "\x89PNG".b)
      Account::LogoFetcher::Icon.new(key:, source:, name:, body:, size:, content_type: "image/png", extension: "png")
    end
end
