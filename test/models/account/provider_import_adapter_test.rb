require "test_helper"

class Account::ProviderImportAdapterTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository)
    @adapter = Account::ProviderImportAdapter.new(@account)
    @family = families(:dylan_family)
  end

  test "imports transaction with all parameters" do
    category = categories(:income)
    merchant = ProviderMerchant.create!(
      provider_merchant_id: "test_merchant_123",
      name: "Test Merchant",
      source: "plaid"
    )

    assert_difference "@account.entries.count", 1 do
      entry = @adapter.import_transaction(
        external_id: "plaid_test_123",
        amount: 100.50,
        currency: "USD",
        date: Date.today,
        name: "Test Transaction",
        source: "plaid",
        category_id: category.id,
        merchant: merchant
      )

      assert_equal 100.50, entry.amount
      assert_equal "USD", entry.currency
      assert_equal Date.today, entry.date
      assert_equal "Test Transaction", entry.name
      assert_equal category.id, entry.transaction.category_id
      assert_equal merchant.id, entry.transaction.merchant_id
    end
  end

  test "imports transaction with minimal parameters" do
    assert_difference "@account.entries.count", 1 do
      entry = @adapter.import_transaction(
        external_id: "simplefin_abc",
        amount: 50.00,
        currency: "USD",
        date: Date.today,
        name: "Simple Transaction",
        source: "simplefin"
      )

      assert_equal 50.00, entry.amount
      assert_equal "simplefin_abc", entry.external_id
      assert_equal "simplefin", entry.source
      assert_nil entry.transaction.category_id
      assert_nil entry.transaction.merchant_id
    end
  end

  test "applies an explicit provider kind on a depository account" do
    entry = @adapter.import_transaction(
      external_id: "up_transfer_1",
      amount: -50.00,
      currency: "USD",
      date: Date.today,
      name: "Transfer to Savings",
      source: "up",
      kind: "funds_movement"
    )

    assert_equal "funds_movement", entry.transaction.kind
  end

  test "account-type kind takes precedence over an explicit provider kind" do
    loan_adapter = Account::ProviderImportAdapter.new(accounts(:loan))

    entry = loan_adapter.import_transaction(
      external_id: "up_loan_repayment_1",
      amount: -200.00,
      currency: "USD",
      date: Date.today,
      name: "Home Loan Repayment",
      source: "up",
      kind: "funds_movement"
    )

    assert_equal "loan_payment", entry.transaction.kind,
                 "a repayment on a Loan account must stay loan_payment, not the provider's funds_movement"
  end

  test "re-importing a matched loan payment leg keeps the kinds its transfer set" do
    loan_adapter = Account::ProviderImportAdapter.new(accounts(:loan))

    loan_entry = loan_adapter.import_transaction(
      external_id: "plaid_loan_inflow_1",
      amount: -200.00,
      currency: "USD",
      date: Date.current,
      name: "Loan Repayment Received",
      source: "plaid"
    )
    checking_entry = @adapter.import_transaction(
      external_id: "plaid_checking_outflow_1",
      amount: 200.00,
      currency: "USD",
      date: Date.current,
      name: "Loan Repayment",
      source: "plaid"
    )

    @family.auto_match_transfers!

    transfer = loan_entry.transaction.reload.transfer
    assert transfer.present?, "expected the two legs to be auto-matched"
    transfer.confirm!
    assert_equal "funds_movement", loan_entry.transaction.kind
    assert_equal "loan_payment", checking_entry.transaction.reload.kind

    # The next sync of the loan account sees a negative amount on a Loan and
    # would classify the leg as loan_payment again, which makes budgets and
    # reports count the same repayment as an expense on both legs.
    loan_adapter.import_transaction(
      external_id: "plaid_loan_inflow_1",
      amount: -200.00,
      currency: "USD",
      date: Date.current,
      name: "Loan Repayment Received",
      source: "plaid"
    )

    assert_equal "funds_movement", loan_entry.transaction.reload.kind
    assert_equal "loan_payment", checking_entry.transaction.reload.kind
  end

  test "re-importing a contribution the user turned into a plain transfer keeps that choice" do
    checking_entry = @adapter.import_transaction(
      external_id: "plaid_checking_to_broker",
      amount: 300.00,
      currency: "USD",
      date: Date.current,
      name: "To broker",
      source: "plaid"
    )
    broker_entry = accounts(:investment).entries.create!(
      name: "From checking", date: Date.current, amount: -300, currency: "USD", entryable: Transaction.new
    )
    transfer = Transfer.create!(inflow_transaction: broker_entry.transaction, outflow_transaction: checking_entry.transaction)
    transfer.confirm!
    transfer.update_investment_contribution!(false)

    # A provider kind hint makes the adapter re-derive the leg from its transfer.
    @adapter.import_transaction(
      external_id: "plaid_checking_to_broker",
      amount: 300.00,
      currency: "USD",
      date: Date.current,
      name: "To broker",
      source: "plaid",
      kind: "standard"
    )

    assert_equal "funds_movement", checking_entry.transaction.reload.kind
  end

  test "re-importing an unconfirmed auto-matched leg does not give it a transfer kind" do
    loan_entry = Account::ProviderImportAdapter.new(accounts(:loan)).import_transaction(
      external_id: "plaid_loan_inflow_pending", amount: -200.00, currency: "USD",
      date: Date.current, name: "Loan Repayment Received", source: "plaid"
    )
    checking_entry = @adapter.import_transaction(
      external_id: "plaid_checking_outflow_pending", amount: 200.00, currency: "USD",
      date: Date.current, name: "Loan Repayment", source: "plaid"
    )

    @family.auto_match_transfers!
    transfer = checking_entry.transaction.reload.transfer
    assert transfer.present?, "expected the two legs to be auto-matched"
    assert transfer.pending?

    @adapter.import_transaction(
      external_id: "plaid_checking_outflow_pending", amount: 200.00, currency: "USD",
      date: Date.current, name: "Loan Repayment", source: "plaid", kind: "funds_movement"
    )

    assert_equal "funds_movement", checking_entry.transaction.reload.kind
    assert_not_equal "loan_payment", checking_entry.transaction.kind
  end

  test "a provider transfer hint does not overwrite the kind of a matched payment leg" do
    loan_entry = Account::ProviderImportAdapter.new(accounts(:loan)).import_transaction(
      external_id: "up_loan_inflow_1",
      amount: -150.00,
      currency: "USD",
      date: Date.current,
      name: "Loan Repayment Received",
      source: "up"
    )
    checking_entry = @adapter.import_transaction(
      external_id: "up_checking_outflow_1",
      amount: 150.00,
      currency: "USD",
      date: Date.current,
      name: "Loan Repayment",
      source: "up"
    )

    @family.auto_match_transfers!
    transfer = checking_entry.transaction.reload.transfer
    assert transfer.present?, "expected the two legs to be auto-matched"
    transfer.confirm!
    assert_equal "loan_payment", checking_entry.transaction.reload.kind

    # Up flags the outgoing leg as an internal transfer (transferAccount).
    @adapter.import_transaction(
      external_id: "up_checking_outflow_1",
      amount: 150.00,
      currency: "USD",
      date: Date.current,
      name: "Loan Repayment",
      source: "up",
      kind: "funds_movement"
    )

    assert_equal "loan_payment", checking_entry.transaction.reload.kind
  end

  test "re-importing a matched leg repairs a kind an earlier sync overwrote" do
    loan_adapter = Account::ProviderImportAdapter.new(accounts(:loan))
    loan_entry = loan_adapter.import_transaction(
      external_id: "plaid_loan_inflow_legacy",
      amount: -300.00,
      currency: "USD",
      date: Date.current,
      name: "Loan Repayment Received",
      source: "plaid"
    )
    @adapter.import_transaction(
      external_id: "plaid_checking_outflow_legacy",
      amount: 300.00,
      currency: "USD",
      date: Date.current,
      name: "Loan Repayment",
      source: "plaid"
    )
    @family.auto_match_transfers!
    assert loan_entry.transaction.reload.transfer.present?, "expected the two legs to be auto-matched"
    loan_entry.transaction.transfer.confirm!

    # State left behind by syncs before the fix: the matched inflow was
    # turned back into loan_payment.
    loan_entry.transaction.update_columns(kind: "loan_payment")

    loan_adapter.import_transaction(
      external_id: "plaid_loan_inflow_legacy",
      amount: -300.00,
      currency: "USD",
      date: Date.current,
      name: "Loan Repayment Received",
      source: "plaid"
    )

    assert_equal "funds_movement", loan_entry.transaction.reload.kind
  end

  test "a rejected match takes the account kind again on re-import" do
    loan_adapter = Account::ProviderImportAdapter.new(accounts(:loan))
    loan_entry = loan_adapter.import_transaction(
      external_id: "plaid_loan_inflow_rejected",
      amount: -120.00,
      currency: "USD",
      date: Date.current,
      name: "Loan Repayment Received",
      source: "plaid"
    )
    @adapter.import_transaction(
      external_id: "plaid_checking_outflow_rejected",
      amount: 120.00,
      currency: "USD",
      date: Date.current,
      name: "Loan Repayment",
      source: "plaid"
    )
    @family.auto_match_transfers!
    loan_entry.transaction.reload.transfer.reject!

    loan_adapter.import_transaction(
      external_id: "plaid_loan_inflow_rejected",
      amount: -120.00,
      currency: "USD",
      date: Date.current,
      name: "Loan Repayment Received",
      source: "plaid"
    )

    assert_nil loan_entry.transaction.reload.transfer
    assert_equal "loan_payment", loan_entry.transaction.kind
  end

  test "an unmatched provider leg still takes the provider kind on re-import" do
    entry = @adapter.import_transaction(
      external_id: "up_unmatched_1",
      amount: -40.00,
      currency: "USD",
      date: Date.current,
      name: "Round Up",
      source: "up"
    )
    assert_equal "standard", entry.transaction.kind

    @adapter.import_transaction(
      external_id: "up_unmatched_1",
      amount: -40.00,
      currency: "USD",
      date: Date.current,
      name: "Round Up",
      source: "up",
      kind: "funds_movement"
    )

    assert_equal "funds_movement", entry.transaction.reload.kind
  end

  test "deriving a matched leg's kind on re-import costs one query per row" do
    amounts = [ 150.00, 160.00, 170.00 ]
    amounts.each_with_index do |amount, i|
      Account::ProviderImportAdapter.new(accounts(:loan)).import_transaction(
        external_id: "up_loan_inflow_batch_#{i}", amount: -amount, currency: "USD",
        date: Date.current, name: "Loan Repayment Received", source: "up"
      )
      @adapter.import_transaction(
        external_id: "up_checking_outflow_batch_#{i}", amount: amount, currency: "USD",
        date: Date.current, name: "Loan Repayment", source: "up"
      )
    end
    @family.auto_match_transfers!
    Transfer.pending.find_each(&:confirm!)

    # Up flags the outgoing legs as internal transfers, so the kind is derived
    # from each leg's transfer; without the hint the adapter derives nothing.
    reimport = lambda do |kind|
      ActiveRecord::Base.uncached do
        capture_sql_queries do
          amounts.each_with_index do |amount, i|
            Account::ProviderImportAdapter.new(@account).import_transaction(
              external_id: "up_checking_outflow_batch_#{i}", amount: amount, currency: "USD",
              date: Date.current, name: "Loan Repayment", source: "up", kind: kind
            )
          end
        end
      end
    end

    without_derivation = reimport.call(nil)
    with_derivation = reimport.call("funds_movement")

    assert_equal without_derivation.size + amounts.size, with_derivation.size,
      "the transfer, its legs and their accounts should load in one query per row"
    amounts.each_index do |i|
      assert_equal "loan_payment", @account.entries.find_by!(external_id: "up_checking_outflow_batch_#{i}").transaction.kind
    end
  end

  test "updates existing transaction instead of creating duplicate" do
    # Create initial transaction
    entry = @adapter.import_transaction(
      external_id: "plaid_duplicate_test",
      amount: 100.00,
      currency: "USD",
      date: Date.today,
      name: "Original Name",
      source: "plaid"
    )

    # Import again with different data - should update, not create new
    assert_no_difference "@account.entries.count" do
      updated_entry = @adapter.import_transaction(
        external_id: "plaid_duplicate_test",
        amount: 200.00,
        currency: "USD",
        date: Date.today,
        name: "Updated Name",
        source: "plaid"
      )

      assert_equal entry.id, updated_entry.id
      assert_equal 200.00, updated_entry.amount
      assert_equal "Updated Name", updated_entry.name
    end
  end

  test "keeps a locked date and amount on re-import" do
    entry = @adapter.import_transaction(
      external_id: "plaid_locked_financials",
      amount: 100.00,
      currency: "USD",
      date: Date.current - 3.days,
      name: "Original Name",
      source: "plaid"
    )

    # A user edit that locks the fields without marking the entry user_modified,
    # as PATCH /api/v1/transactions/:id does when user_modified is not sent.
    entry.update!(date: Date.current - 1.day, amount: 80.00)
    entry.lock_saved_attributes!
    assert_not entry.reload.user_modified?

    updated_entry = @adapter.import_transaction(
      external_id: "plaid_locked_financials",
      amount: 100.00,
      currency: "EUR",
      date: Date.current - 3.days,
      name: "Provider Name",
      source: "plaid"
    )

    assert_equal entry.id, updated_entry.id
    assert_equal Date.current - 1.day, updated_entry.reload.date
    assert_equal 80.00, updated_entry.amount
    assert_equal "USD", updated_entry.currency
    assert_equal "Provider Name", updated_entry.name
  end

  test "classifies a re-imported loan entry by its locked amount, not the provider's" do
    loan_adapter = Account::ProviderImportAdapter.new(accounts(:loan))
    entry = loan_adapter.import_transaction(
      external_id: "plaid_loan_locked_amount",
      amount: -200.00,
      currency: "USD",
      date: Date.current,
      name: "Loan Repayment",
      source: "plaid"
    )
    assert_equal "loan_payment", entry.transaction.kind

    entry.update!(amount: 50.00)
    entry.lock_saved_attributes!
    entry.transaction.update!(kind: "standard")

    loan_adapter.import_transaction(
      external_id: "plaid_loan_locked_amount",
      amount: -200.00,
      currency: "USD",
      date: Date.current,
      name: "Loan Repayment",
      source: "plaid"
    )

    assert_equal 50.00, entry.reload.amount
    assert_equal "standard", entry.transaction.kind
  end

  test "updates an unlocked amount while keeping a locked date" do
    entry = @adapter.import_transaction(
      external_id: "plaid_locked_date_only",
      amount: 100.00,
      currency: "USD",
      date: Date.current - 3.days,
      name: "Original Name",
      source: "plaid"
    )

    entry.update!(date: Date.current - 1.day)
    entry.lock_saved_attributes!

    updated_entry = @adapter.import_transaction(
      external_id: "plaid_locked_date_only",
      amount: 120.00,
      currency: "USD",
      date: Date.current - 3.days,
      name: "Original Name",
      source: "plaid"
    )

    assert_equal Date.current - 1.day, updated_entry.reload.date
    assert_equal 120.00, updated_entry.amount
  end

  test "allows same external_id from different sources without collision" do
    # Create transaction from SimpleFin with ID "transaction_123"
    simplefin_entry = @adapter.import_transaction(
      external_id: "transaction_123",
      amount: 100.00,
      currency: "USD",
      date: Date.today,
      name: "SimpleFin Transaction",
      source: "simplefin"
    )

    # Create transaction from Plaid with same ID "transaction_123" - should NOT collide
    # because external_id is unique per (account, source) combination
    assert_difference "@account.entries.count", 1 do
      plaid_entry = @adapter.import_transaction(
        external_id: "transaction_123",
        amount: 200.00,
        currency: "USD",
        date: Date.today,
        name: "Plaid Transaction",
        source: "plaid"
      )

      # Should be different entries
      assert_not_equal simplefin_entry.id, plaid_entry.id
      assert_equal "simplefin", simplefin_entry.source
      assert_equal "plaid", plaid_entry.source
      assert_equal "transaction_123", simplefin_entry.external_id
      assert_equal "transaction_123", plaid_entry.external_id
    end
  end

  test "raises error when external_id is missing" do
    exception = assert_raises(ArgumentError) do
      @adapter.import_transaction(
        external_id: "",
        amount: 100.00,
        currency: "USD",
        date: Date.today,
        name: "Test",
        source: "plaid"
      )
    end

    assert_equal "external_id is required", exception.message
  end

  test "raises error when source is missing" do
    exception = assert_raises(ArgumentError) do
      @adapter.import_transaction(
        external_id: "test_123",
        amount: 100.00,
        currency: "USD",
        date: Date.today,
        name: "Test",
        source: ""
      )
    end

    assert_equal "source is required", exception.message
  end

  test "finds or creates merchant with all data" do
    assert_difference "ProviderMerchant.count", 1 do
      merchant = @adapter.find_or_create_merchant(
        provider_merchant_id: "plaid_merchant_123",
        name: "Test Merchant",
        source: "plaid",
        website_url: "https://example.com",
        logo_url: "https://example.com/logo.png"
      )

      assert_equal "Test Merchant", merchant.name
      assert_equal "plaid", merchant.source
      assert_equal "plaid_merchant_123", merchant.provider_merchant_id
      assert_equal "https://example.com", merchant.website_url
      assert_equal "https://example.com/logo.png", merchant.logo_url
    end
  end

  # Issue #2925: Akahu (and sometimes Plaid) supply a website but no logo.
  test "creates a website-only merchant with a Brandfetch logo" do
    Setting.stubs(:brand_fetch_client_id).returns("test_client_id")
    Setting.stubs(:brand_fetch_logo_size).returns(40)

    merchant = @adapter.find_or_create_merchant(
      provider_merchant_id: "akahu_merchant_123",
      name: "Countdown",
      source: "akahu",
      website_url: "https://www.countdown.co.nz"
    )

    assert_equal "https://cdn.brandfetch.io/countdown.co.nz/icon/fallback/lettermark/w/40/h/40?c=test_client_id", merchant.logo_url
  end

  test "returns nil when merchant data is insufficient" do
    merchant = @adapter.find_or_create_merchant(
      provider_merchant_id: "",
      name: "",
      source: "plaid"
    )

    assert_nil merchant
  end

  test "finds existing merchant instead of creating duplicate" do
    existing_merchant = ProviderMerchant.create!(
      provider_merchant_id: "existing_123",
      name: "Existing Merchant",
      source: "plaid"
    )

    assert_no_difference "ProviderMerchant.count" do
      merchant = @adapter.find_or_create_merchant(
        provider_merchant_id: "existing_123",
        name: "Existing Merchant",
        source: "plaid"
      )

      assert_equal existing_merchant.id, merchant.id
    end
  end

  test "updates account balance" do
    @adapter.update_balance(
      balance: 5000.00,
      cash_balance: 4500.00,
      source: "plaid"
    )

    @account.reload
    assert_equal 5000.00, @account.balance
    assert_equal 4500.00, @account.cash_balance
  end

  test "updates account balance without cash_balance" do
    @adapter.update_balance(
      balance: 3000.00,
      source: "simplefin"
    )

    @account.reload
    assert_equal 3000.00, @account.balance
    assert_equal 3000.00, @account.cash_balance
  end

  test "imports holding with all parameters" do
    investment_account = accounts(:investment)
    adapter = Account::ProviderImportAdapter.new(investment_account)
    security = securities(:aapl)

    # Use a date that doesn't conflict with fixtures (fixtures use today and 1.day.ago)
    holding_date = Date.today - 2.days

    assert_difference "investment_account.holdings.count", 1 do
      holding = adapter.import_holding(
        security: security,
        quantity: 10.5,
        amount: 1575.00,
        currency: "USD",
        date: holding_date,
        price: 150.00,
        source: "plaid"
      )

      assert_equal security.id, holding.security_id
      assert_equal 10.5, holding.qty
      assert_equal 1575.00, holding.amount
      assert_equal 150.00, holding.price
      assert_equal holding_date, holding.date
    end
  end

  test "raises error when security is missing for holding import" do
    exception = assert_raises(ArgumentError) do
      @adapter.import_holding(
        security: nil,
        quantity: 10,
        amount: 1000,
        currency: "USD",
        date: Date.today,
        source: "plaid"
      )
    end

    assert_equal "security is required", exception.message
  end

  test "imports trade with all parameters" do
    investment_account = accounts(:investment)
    adapter = Account::ProviderImportAdapter.new(investment_account)
    security = securities(:aapl)

    assert_difference "investment_account.entries.count", 1 do
      entry = adapter.import_trade(
        security: security,
        quantity: 5,
        price: 150.00,
        amount: 754.95,
        fee: 4.95,
        currency: "USD",
        date: Date.today,
        source: "plaid"
      )

      assert_kind_of Trade, entry.entryable
      assert_equal 5, entry.entryable.qty
      assert_equal 150.00, entry.entryable.price
      assert_equal BigDecimal("4.95"), entry.entryable.fee
      assert_equal BigDecimal("754.95"), entry.amount
      assert_match(/Buy.*5.*shares/i, entry.name)
    end
  end

  test "imports trade with provider exchange rate" do
    investment_account = accounts(:investment)
    adapter = Account::ProviderImportAdapter.new(investment_account)
    security = securities(:aapl)

    entry = adapter.import_trade(
      security: security,
      quantity: 5,
      price: 150.00,
      amount: 750.00,
      currency: "USD",
      date: Date.today,
      source: "plaid",
      exchange_rate: 0.91
    )

    assert_equal 0.91, entry.entryable.exchange_rate
  end

  # So user-entered fees aren't erased by syncing from providers that don't report fees
  test "preserves existing trade fee when reimport omits it" do
    investment_account = accounts(:investment)
    adapter = Account::ProviderImportAdapter.new(investment_account)
    aapl = securities(:aapl)

    entry = adapter.import_trade(
      external_id: "plaid_trade_fee_preserved",
      security: aapl,
      quantity: 5,
      price: 150.00,
      amount: 754.95,
      fee: 4.95,
      currency: "USD",
      date: Date.today,
      source: "plaid"
    )

    updated_entry = adapter.import_trade(
      external_id: "plaid_trade_fee_preserved",
      security: aapl,
      quantity: 5,
      price: 150.00,
      amount: 754.95,
      currency: "USD",
      date: Date.today,
      source: "plaid"
    )

    assert_equal entry.id, updated_entry.id
    assert_equal BigDecimal("4.95"), updated_entry.entryable.reload.fee
  end

  test "raises error when security is missing for trade import" do
    exception = assert_raises(ArgumentError) do
      @adapter.import_trade(
        security: nil,
        quantity: 5,
        price: 100,
        amount: 500,
        currency: "USD",
        date: Date.today,
        source: "plaid"
      )
    end

    assert_equal "security is required", exception.message
  end

  test "carries a remapped security forward to the next day's holding" do
    account, adapter = provider_holding_setup
    reported = Security.create!(ticker: "RPTD", name: "Reported Fund")
    chosen = Security.create!(ticker: "CHSN", name: "Chosen Fund")
    first_day = 20.days.ago.to_date

    import_daily_holding(adapter, reported, first_day).remap_security!(chosen)
    next_day = import_daily_holding(adapter, reported, first_day + 1)

    assert_equal chosen.id, next_day.security_id
    assert_equal reported.id, next_day.provider_security_id
    assert next_day.security_locked?
    assert_equal 2, account.holdings.where(security: chosen).count
  end

  test "carries a locked cost basis forward to the next day's holding" do
    _account, adapter = provider_holding_setup
    security = Security.create!(ticker: "LCKD", name: "Locked Basis Fund")
    first_day = 20.days.ago.to_date

    import_daily_holding(adapter, security, first_day).set_manual_cost_basis!(42)
    next_day = import_daily_holding(adapter, security, first_day + 1, cost_basis: 10)

    assert_equal 42, next_day.cost_basis
    assert_equal "manual", next_day.cost_basis_source
    assert next_day.cost_basis_locked?
  end

  test "does not revive a correction the user has since undone" do
    _account, adapter = provider_holding_setup
    security = Security.create!(ticker: "UNDO", name: "Unlocked Basis Fund")
    first_day = 20.days.ago.to_date

    import_daily_holding(adapter, security, first_day).set_manual_cost_basis!(42)
    import_daily_holding(adapter, security, first_day + 1).unlock_cost_basis!
    third_day = import_daily_holding(adapter, security, first_day + 2, cost_basis: 10)

    assert_equal 10, third_day.cost_basis
    assert_equal "provider", third_day.cost_basis_source
    assert_not third_day.cost_basis_locked?
  end

  test "a second same-day import of a remapped position's provider row updates today's row" do
    account, adapter = provider_holding_setup
    original = Security.create!(ticker: "DUPE", name: "Provider Row")
    chosen = Security.create!(ticker: "DUPE", name: "Chosen Row", exchange_operating_mic: "XNYS")
    yesterday = Date.current - 1

    import_holding_without_external_id(adapter, original, yesterday).remap_security!(chosen)
    import_holding_without_external_id(adapter, original, Date.current)

    assert_nothing_raised do
      import_holding_without_external_id(adapter, original, Date.current, quantity: 12)
    end

    today = account.holdings.where(security: [ original, chosen ], date: Date.current, currency: "USD")
    assert_equal [ chosen.id ], today.pluck(:security_id)
    assert_equal 12, today.first.qty
  end

  test "a remapped position's chosen row carries the lock and the original provider row forward" do
    account, adapter = provider_holding_setup
    original = Security.create!(ticker: "PICK", name: "Provider Row")
    chosen = Security.create!(ticker: "PICK", name: "Chosen Row", exchange_operating_mic: "XNYS")
    yesterday = Date.current - 1

    earlier = import_holding_without_external_id(adapter, original, yesterday)
    earlier.remap_security!(chosen)
    earlier.set_manual_cost_basis!(42)

    today = import_holding_without_external_id(adapter, chosen, Date.current, cost_basis: 10)

    assert_equal chosen.id, today.security_id
    assert today.security_locked?
    assert_equal original.id, today.provider_security_id
    assert_equal 42, today.cost_basis
    assert today.cost_basis_locked?
    assert_equal 1, account.holdings.where(security: [ original, chosen ], date: Date.current).count
  end

  # Chained remaps: the user moved the provider's A onto B, and the provider's B
  # onto C. An incoming B matches yesterday's B->C row by provider security and
  # the A->B row as a correction locked to B, both on the same date. The
  # provider-security match is the position B came from, so it wins. The A->B
  # row is created first and has the lower id, so neither insertion order nor
  # an id tiebreak alone would return the right one.
  test "a chained remap carries forward the row the provider security came from" do
    account, adapter = provider_holding_setup
    first = Security.create!(ticker: "CHNA", name: "Provider A")
    middle = Security.create!(ticker: "CHNB", name: "Provider B, chosen for A")
    last = Security.create!(ticker: "CHNC", name: "Chosen for B")
    yesterday = Date.current - 1
    account.holdings.create!(
      id: "00000000-0000-4000-8000-000000000001", security: middle, provider_security: first, security_locked: true,
      date: yesterday, currency: "USD", qty: 1, price: 10, amount: 10, cost_basis: 11, cost_basis_locked: true
    )
    account.holdings.create!(
      id: "ffffffff-ffff-4fff-bfff-ffffffffffff", security: last, provider_security: middle, security_locked: true,
      date: yesterday, currency: "USD", qty: 2, price: 10, amount: 20, cost_basis: 22, cost_basis_locked: true
    )

    today = import_holding_without_external_id(adapter, middle, Date.current)

    assert_equal last.id, today.security_id
    assert_equal middle.id, today.provider_security_id
    assert_equal 22, today.cost_basis
  end

  test "an unlocked earlier row on the chosen security is not treated as a correction" do
    account, adapter = provider_holding_setup
    original = Security.create!(ticker: "OPEN", name: "Provider Row")
    chosen = Security.create!(ticker: "OPEN", name: "Chosen Row", exchange_operating_mic: "XNYS")
    account.holdings.create!(
      security: chosen, provider_security: original, security_locked: false,
      date: Date.current - 1, currency: "USD", qty: 10, price: 100, amount: 1000,
      cost_basis: 42, cost_basis_source: "manual", cost_basis_locked: true
    )

    today = import_holding_without_external_id(adapter, chosen, Date.current, cost_basis: 10)

    assert_not today.security_locked?
    assert_equal chosen.id, today.provider_security_id
    assert_equal 10, today.cost_basis
    assert_equal "provider", today.cost_basis_source
    assert_not today.cost_basis_locked?
  end

  test "does not delete future holdings when can_delete_holdings? returns false" do
    investment_account = accounts(:investment)
    adapter = Account::ProviderImportAdapter.new(investment_account)
    security = securities(:aapl)

    # Create a future holding
    future_holding = investment_account.holdings.create!(
      security: security,
      qty: 5,
      amount: 750,
      currency: "USD",
      date: Date.today + 30.days,
      price: 150
    )

    # Mock can_delete_holdings? to return false
    investment_account.expects(:can_delete_holdings?).returns(false)

    # Import a holding with delete_future_holdings flag
    adapter.import_holding(
      security: security,
      quantity: 10,
      amount: 1500,
      currency: "USD",
      date: Date.today,
      price: 150,
      source: "plaid",
      delete_future_holdings: true
    )

    # Future holding should still exist
    assert Holding.exists?(future_holding.id)
  end

  test "deletes all future holdings when account_provider_id is not provided and can_delete_holdings? returns true" do
    investment_account = accounts(:investment)
    adapter = Account::ProviderImportAdapter.new(investment_account)
    security = securities(:aapl)

    # Create two future holdings
    future_holding_1 = investment_account.holdings.create!(
      security: security,
      qty: 5,
      amount: 750,
      currency: "USD",
      date: Date.today + 121.days,
      price: 150
    )

    future_holding_2 = investment_account.holdings.create!(
      security: security,
      qty: 3,
      amount: 450,
      currency: "USD",
      date: Date.today + 2.days,
      price: 150
    )

    # Mock can_delete_holdings? to return true
    investment_account.expects(:can_delete_holdings?).returns(true)

    # Import a holding without account_provider_id
    adapter.import_holding(
      security: security,
      quantity: 10,
      amount: 1500,
      currency: "USD",
      date: Date.today,
      price: 150,
      source: "plaid",
      delete_future_holdings: true
    )

    # All future holdings should be deleted
    assert_not Holding.exists?(future_holding_1.id)
    assert_not Holding.exists?(future_holding_2.id)
  end

  test "updates existing trade attributes instead of keeping stale data" do
    investment_account = accounts(:investment)
    adapter = Account::ProviderImportAdapter.new(investment_account)
    aapl = securities(:aapl)
    msft = securities(:msft)

    # Create initial trade
    entry = adapter.import_trade(
      external_id: "plaid_trade_123",
      security: aapl,
      quantity: 5,
      price: 150.00,
      amount: 750.00,
      currency: "USD",
      date: Date.today,
      source: "plaid"
    )

    # Import again with updated attributes - should update Trade, not keep stale data
    assert_no_difference "investment_account.entries.count" do
      updated_entry = adapter.import_trade(
        external_id: "plaid_trade_123",
        security: msft,
        quantity: 10,
        price: 200.00,
        amount: 2000.00,
        currency: "USD",
        date: Date.today,
        source: "plaid",
        exchange_rate: 0.95
      )

      assert_equal entry.id, updated_entry.id
      # Trade attributes should be updated
      assert_equal msft.id, updated_entry.entryable.security_id
      assert_equal 10, updated_entry.entryable.qty
      assert_equal 200.00, updated_entry.entryable.price
      assert_equal "USD", updated_entry.entryable.currency
      assert_equal 0.95, updated_entry.entryable.exchange_rate
      # Entry attributes should also be updated
      assert_equal 2000.00, updated_entry.amount
    end
  end

  test "preserves existing exchange rate when reimport omits it" do
    investment_account = accounts(:investment)
    adapter = Account::ProviderImportAdapter.new(investment_account)
    aapl = securities(:aapl)

    entry = adapter.import_trade(
      external_id: "plaid_trade_exchange_rate_preserved",
      security: aapl,
      quantity: 5,
      price: 150.00,
      amount: 750.00,
      currency: "USD",
      date: Date.today,
      source: "plaid",
      exchange_rate: 0.95
    )

    assert_no_difference "investment_account.entries.count" do
      updated_entry = adapter.import_trade(
        external_id: "plaid_trade_exchange_rate_preserved",
        security: aapl,
        quantity: 10,
        price: 200.00,
        amount: 2000.00,
        currency: "USD",
        date: Date.today,
        source: "plaid"
      )

      assert_equal entry.id, updated_entry.id
      assert_equal 0.95, updated_entry.entryable.exchange_rate
    end
  end

  test "raises error when external_id collision occurs across different entryable types for transaction" do
    investment_account = accounts(:investment)
    adapter = Account::ProviderImportAdapter.new(investment_account)
    security = securities(:aapl)

    # Create a trade with external_id "collision_test"
    adapter.import_trade(
      external_id: "collision_test",
      security: security,
      quantity: 5,
      price: 150.00,
      amount: 750.00,
      currency: "USD",
      date: Date.today,
      source: "plaid"
    )

    # Try to create a transaction with the same external_id and source
    exception = assert_raises(ArgumentError) do
      adapter.import_transaction(
        external_id: "collision_test",
        amount: 100.00,
        currency: "USD",
        date: Date.today,
        name: "Test Transaction",
        source: "plaid"
      )
    end

    assert_match(/Entry with external_id.*already exists with different entryable type/i, exception.message)
  end

  test "raises error when external_id collision occurs across different entryable types for trade" do
    investment_account = accounts(:investment)
    adapter = Account::ProviderImportAdapter.new(investment_account)
    security = securities(:aapl)

    # Create a transaction with external_id "collision_test_2"
    adapter.import_transaction(
      external_id: "collision_test_2",
      amount: 100.00,
      currency: "USD",
      date: Date.today,
      name: "Test Transaction",
      source: "plaid"
    )

    # Try to create a trade with the same external_id and source
    exception = assert_raises(ArgumentError) do
      adapter.import_trade(
        external_id: "collision_test_2",
        security: security,
        quantity: 5,
        price: 150.00,
        amount: 750.00,
        currency: "USD",
        date: Date.today,
        source: "plaid"
      )
    end

    assert_match(/Entry with external_id.*already exists with different entryable type/i, exception.message)
  end

  test "claims manual transaction when provider syncs matching transaction" do
    # Create a manual transaction (no external_id or source)
    manual_entry = @account.entries.create!(
      date: Date.today,
      amount: 42.50,
      currency: "USD",
      name: "Coffee Shop",
      entryable: Transaction.new
    )

    assert_nil manual_entry.external_id
    assert_nil manual_entry.source

    # Provider syncs a matching transaction - should claim the manual entry, not create new
    assert_no_difference "@account.entries.count" do
      entry = @adapter.import_transaction(
        external_id: "lunchflow_12345",
        amount: 42.50,
        currency: "USD",
        date: Date.today,
        name: "Coffee Shop - Lunchflow",
        source: "lunchflow"
      )

      # Should be the same entry, now claimed by the provider
      assert_equal manual_entry.id, entry.id
      assert_equal "lunchflow_12345", entry.external_id
      assert_equal "lunchflow", entry.source
      assert_equal "Coffee Shop - Lunchflow", entry.name
    end
  end

  test "never claims a part of a split entry for a matching provider transaction" do
    parent = @account.entries.create!(date: Date.today, amount: 37.50, currency: "USD", name: "Market", entryable: Transaction.new)
    parent.split!([ { name: "Groceries", amount: 25, category_id: nil }, { name: "Household", amount: 12.50, category_id: nil } ])
    household = parent.child_entries.find_by!(name: "Household")

    entry = nil
    assert_difference "@account.entries.count", 1 do
      entry = @adapter.import_transaction(external_id: "lunchflow_678", amount: 12.50, currency: "USD", date: Date.today,
                                          name: "Hardware store", source: "lunchflow")
    end

    assert_not_equal household.id, entry.id
    assert_equal [ nil, nil, "Household", parent.id ], household.reload.values_at(:external_id, :source, :name, :parent_entry_id)
  end

  test "claims CSV imported transaction when provider syncs matching transaction" do
    # Create a CSV imported transaction (has import_id but no external_id)
    import = Import.create!(
      family: @family,
      type: "TransactionImport",
      status: :complete
    )

    csv_entry = @account.entries.create!(
      date: Date.today - 1.day,
      amount: 125.00,
      currency: "USD",
      name: "Grocery Store",
      import: import,
      entryable: Transaction.new
    )

    assert_nil csv_entry.external_id
    assert_nil csv_entry.source
    assert_equal import.id, csv_entry.import_id

    # Provider syncs a matching transaction - should claim the CSV entry
    assert_no_difference "@account.entries.count" do
      entry = @adapter.import_transaction(
        external_id: "plaid_csv_match",
        amount: 125.00,
        currency: "USD",
        date: Date.today - 1.day,
        name: "Grocery Store - Plaid",
        source: "plaid"
      )

      # Should be the same entry, now claimed by the provider
      assert_equal csv_entry.id, entry.id
      assert_equal "plaid_csv_match", entry.external_id
      assert_equal "plaid", entry.source
      assert_equal import.id, entry.import_id # Should preserve the import_id
    end
  end

  test "does not claim transaction when date does not match" do
    # Create a manual transaction
    manual_entry = @account.entries.create!(
      date: Date.today - 5.days,
      amount: 50.00,
      currency: "USD",
      name: "Restaurant",
      entryable: Transaction.new
    )

    # Provider syncs similar transaction but different date - should create new entry
    assert_difference "@account.entries.count", 1 do
      entry = @adapter.import_transaction(
        external_id: "lunchflow_different_date",
        amount: 50.00,
        currency: "USD",
        date: Date.today,
        name: "Restaurant",
        source: "lunchflow"
      )

      # Should be a different entry
      assert_not_equal manual_entry.id, entry.id
    end
  end

  test "does not claim transaction when amount does not match" do
    # Create a manual transaction
    manual_entry = @account.entries.create!(
      date: Date.today,
      amount: 50.00,
      currency: "USD",
      name: "Restaurant",
      entryable: Transaction.new
    )

    # Provider syncs similar transaction but different amount - should create new entry
    assert_difference "@account.entries.count", 1 do
      entry = @adapter.import_transaction(
        external_id: "lunchflow_different_amount",
        amount: 51.00,
        currency: "USD",
        date: Date.today,
        name: "Restaurant",
        source: "lunchflow"
      )

      # Should be a different entry
      assert_not_equal manual_entry.id, entry.id
    end
  end

  test "does not claim transaction when currency does not match" do
    # Create a manual transaction
    manual_entry = @account.entries.create!(
      date: Date.today,
      amount: 50.00,
      currency: "EUR",
      name: "Restaurant",
      entryable: Transaction.new
    )

    # Provider syncs similar transaction but different currency - should create new entry
    assert_difference "@account.entries.count", 1 do
      entry = @adapter.import_transaction(
        external_id: "lunchflow_different_currency",
        amount: 50.00,
        currency: "USD",
        date: Date.today,
        name: "Restaurant",
        source: "lunchflow"
      )

      # Should be a different entry
      assert_not_equal manual_entry.id, entry.id
    end
  end

  test "does not claim transaction that already has external_id from different provider" do
    # Create a transaction already synced from SimpleFin
    simplefin_entry = @adapter.import_transaction(
      external_id: "simplefin_123",
      amount: 30.00,
      currency: "USD",
      date: Date.today,
      name: "Gas Station",
      source: "simplefin"
    )

    # Provider (Lunchflow) syncs matching transaction - should create new entry, not claim SimpleFin's
    assert_difference "@account.entries.count", 1 do
      entry = @adapter.import_transaction(
        external_id: "lunchflow_gas",
        amount: 30.00,
        currency: "USD",
        date: Date.today,
        name: "Gas Station",
        source: "lunchflow"
      )

      # Should be a different entry because SimpleFin already claimed it
      assert_not_equal simplefin_entry.id, entry.id
      assert_equal "lunchflow", entry.source
      assert_equal "simplefin", simplefin_entry.reload.source
    end
  end

  test "claims oldest matching manual transaction when multiple exist" do
    # Create multiple manual transactions with same date, amount, currency
    older_entry = @account.entries.create!(
      date: Date.today,
      amount: 20.00,
      currency: "USD",
      name: "Parking - Old",
      entryable: Transaction.new,
      created_at: 2.hours.ago
    )

    newer_entry = @account.entries.create!(
      date: Date.today,
      amount: 20.00,
      currency: "USD",
      name: "Parking - New",
      entryable: Transaction.new,
      created_at: 1.hour.ago
    )

    # Provider syncs matching transaction - should claim the oldest one
    assert_no_difference "@account.entries.count" do
      entry = @adapter.import_transaction(
        external_id: "lunchflow_parking",
        amount: 20.00,
        currency: "USD",
        date: Date.today,
        name: "Parking - Provider",
        source: "lunchflow"
      )

      # Should claim the older entry
      assert_equal older_entry.id, entry.id
      assert_equal "lunchflow_parking", entry.external_id

      # Newer entry should remain unclaimed
      assert_nil newer_entry.reload.external_id
    end
  end

  # ============================================================================
  # Plaid pending_transaction_id Tests
  # ============================================================================

  test "reconciles pending via Plaid pending_transaction_id" do
    # Import a pending transaction
    pending_entry = @adapter.import_transaction(
      external_id: "plaid_pending_abc",
      amount: 42.00,
      currency: "USD",
      date: Date.today - 2.days,
      name: "Coffee Shop",
      source: "plaid",
      extra: { "plaid" => { "pending" => true } }
    )

    # Import posted with pending_transaction_id linking to the pending
    assert_no_difference "@account.entries.count" do
      posted_entry = @adapter.import_transaction(
        external_id: "plaid_posted_xyz",
        amount: 42.00,
        currency: "USD",
        date: Date.today,
        name: "Coffee Shop",
        source: "plaid",
        pending_transaction_id: "plaid_pending_abc", # Links to pending
        extra: { "plaid" => { "pending" => false, "pending_transaction_id" => "plaid_pending_abc" } }
      )

      # Should claim the pending entry
      assert_equal pending_entry.id, posted_entry.id
      assert_equal "plaid_posted_xyz", posted_entry.external_id
      assert_not posted_entry.transaction.pending?
    end
  end

  test "preserves transaction tags when re-importing existing transaction" do
    tag = Tag.create!(name: "Salary", family: @family)

    # Create initial transaction
    entry = @adapter.import_transaction(
      external_id: "plaid_tag_test",
      amount: 1000.00,
      currency: "USD",
      date: Date.today,
      name: "Paycheck",
      source: "plaid"
    )

    # Add tag to the transaction (simulating user or rule action)
    entry.transaction.tags << tag
    entry.transaction.save!
    assert_equal [ tag ], entry.transaction.reload.tags

    # Re-import the same transaction with updated data
    assert_no_difference "@account.entries.count" do
      updated_entry = @adapter.import_transaction(
        external_id: "plaid_tag_test",
        amount: 1000.00,
        currency: "USD",
        date: Date.today,
        name: "Updated Paycheck Name",
        source: "plaid"
      )

      assert_equal entry.id, updated_entry.id
      # Tags should be preserved
      assert_equal [ tag ], updated_entry.transaction.reload.tags
    end
  end

  test "Plaid pending_transaction_id takes priority over amount matching" do
    # Create TWO pending transactions with same amount
    pending1 = @adapter.import_transaction(
      external_id: "plaid_pending_1",
      amount: 25.00,
      currency: "USD",
      date: Date.today - 1.day,
      name: "Store A",
      source: "plaid",
      extra: { "plaid" => { "pending" => true } }
    )

    pending2 = @adapter.import_transaction(
      external_id: "plaid_pending_2",
      amount: 25.00,
      currency: "USD",
      date: Date.today - 1.day,
      name: "Store B",
      source: "plaid",
      extra: { "plaid" => { "pending" => true } }
    )

    # Import posted that explicitly links to pending2 via pending_transaction_id
    assert_no_difference "@account.entries.count" do
      posted_entry = @adapter.import_transaction(
        external_id: "plaid_posted_linked",
        amount: 25.00,
        currency: "USD",
        date: Date.today,
        name: "Store B",
        source: "plaid",
        pending_transaction_id: "plaid_pending_2", # Explicitly links to pending2
        extra: { "plaid" => { "pending" => false } }
      )

      # Should claim pending2 specifically (not pending1)
      assert_equal pending2.id, posted_entry.id
      assert_equal "plaid_posted_linked", posted_entry.external_id
    end

    # pending1 should still exist as pending
    pending1.reload
    assert_equal "plaid_pending_1", pending1.external_id
  end

  # Provider metadata is not user-editable, so a user edit elsewhere on the entry
  # must not freeze it: the drawer has to reflect what the provider last sent,
  # including dropping fields it no longer sends.
  test "refreshes provider metadata on a user-modified entry" do
    entry = @adapter.import_transaction(
      external_id: "user_mod_extra",
      amount: 12.0,
      currency: "USD",
      date: Date.today,
      name: "Amazon",
      source: "plaid",
      extra: { "plaid" => { "payment_channel" => "online", "payment_meta" => { "payee" => "Amazon" } } },
      replace_extra_namespaces: [ "plaid" ]
    )

    entry.transaction.lock_attr!(:category_id)
    entry.mark_user_modified!

    @adapter.import_transaction(
      external_id: "user_mod_extra",
      amount: 12.0,
      currency: "USD",
      date: Date.today,
      name: "Amazon",
      source: "plaid",
      extra: { "plaid" => { "payment_channel" => "in store" } },
      replace_extra_namespaces: [ "plaid" ]
    )

    plaid_extra = entry.reload.transaction.extra.fetch("plaid")
    assert_equal "in store", plaid_extra["payment_channel"]
    assert_nil plaid_extra["payment_meta"], "a dropped field must not survive on a user-modified entry"
  end

  # determine_skip_reason reports "user_modified" before it checks import_locked?,
  # so an entry with both flags reaches that branch. Import ownership wins.
  test "leaves metadata alone on an entry that is also import-locked" do
    entry = @adapter.import_transaction(
      external_id: "user_mod_import_locked",
      amount: 12.0,
      currency: "USD",
      date: Date.today,
      name: "Amazon",
      source: "plaid",
      extra: { "plaid" => { "payment_channel" => "online" } },
      replace_extra_namespaces: [ "plaid" ]
    )

    entry.update!(import_locked: true)
    entry.mark_user_modified!

    @adapter.import_transaction(
      external_id: "user_mod_import_locked",
      amount: 12.0,
      currency: "USD",
      date: Date.today,
      name: "Amazon",
      source: "plaid",
      extra: { "plaid" => { "payment_channel" => "in store" } },
      replace_extra_namespaces: [ "plaid" ]
    )

    assert_equal "online", entry.reload.transaction.extra.dig("plaid", "payment_channel")
  end

  # extra is not uniformly provider-owned. Transaction#exchange_rate lives at
  # extra["exchange_rate"], is editable through the transaction form, and drives
  # balance conversion — so refreshing a protected entry must touch only the
  # namespaces the provider declared, not the whole payload.
  test "refreshing a protected entry leaves user-owned extra keys alone" do
    entry = @adapter.import_transaction(
      external_id: "user_mod_exchange_rate",
      amount: 12.0,
      currency: "EUR",
      date: Date.today,
      name: "Wise transfer",
      source: "wise",
      extra: { "exchange_rate" => "1.05", "wise" => { "status" => "pending" } },
      replace_extra_namespaces: [ "wise" ]
    )

    # The user corrects the rate by hand, which protects the entry.
    entry.transaction.update!(exchange_rate: "1.23")
    entry.mark_user_modified!

    @adapter.import_transaction(
      external_id: "user_mod_exchange_rate",
      amount: 12.0,
      currency: "EUR",
      date: Date.today,
      name: "Wise transfer",
      source: "wise",
      extra: { "exchange_rate" => "1.05", "wise" => { "status" => "outgoing_payment_sent" } },
      replace_extra_namespaces: [ "wise" ]
    )

    refreshed = entry.reload.transaction

    assert_equal "1.23", refreshed.extra["exchange_rate"].to_s,
      "the provider must not overwrite a rate the user typed"
    assert_equal "outgoing_payment_sent", refreshed.extra.dig("wise", "status"),
      "the provider's own namespace should still refresh"
  end

  private

    def capture_sql_queries
      queries = []
      callback = lambda do |_name, _started, _finished, _unique_id, payload|
        next if payload[:cached]
        next if %w[SCHEMA TRANSACTION].include?(payload[:name])

        queries << payload[:sql].squish
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        yield
      end

      queries
    end

    def provider_holding_setup
      account = accounts(:investment)
      [ account, Account::ProviderImportAdapter.new(account) ]
    end

    # One provider snapshot per day, identified the way the daily-snapshot
    # processors do it: the provider's id suffixed with the date.
    def import_daily_holding(adapter, security, date, cost_basis: nil)
      adapter.import_holding(
        security: security,
        quantity: 10,
        amount: 1000,
        currency: "USD",
        date: date,
        price: 100,
        cost_basis: cost_basis,
        external_id: "provider_lot_#{date}",
        source: "plaid"
      )
    end

    # A provider that sends no external_id (Plaid, Indexa Capital, SnapTrade
    # securities): the row is keyed by security, date and currency.
    def import_holding_without_external_id(adapter, security, date, quantity: 10, cost_basis: nil)
      adapter.import_holding(
        security: security,
        quantity: quantity,
        amount: quantity * 100,
        currency: "USD",
        date: date,
        price: 100,
        cost_basis: cost_basis,
        source: "plaid"
      )
    end
end
