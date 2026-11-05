namespace :data_migration do
  desc "Migrate duplicate securities"
  # 2025-05-22: older data allowed multiple rows with the same
  # ticker / exchange_operating_mic (case-insensitive, NULLs collapsed).
  # This task:
  #   1. Finds each duplicate group
  #   2. Chooses the earliest-created row as the keeper
  #   3. Re-points holdings and trades to the keeper
  #   4. Destroys the duplicate (which also removes its prices)
  task migrate_duplicate_securities: :environment do
    puts "==> Scanning for duplicate securities…"

    duplicate_sets = Security
      .select("UPPER(ticker) AS up_ticker,
               COALESCE(UPPER(exchange_operating_mic), '') AS up_mic,
               COUNT(*) AS dup_count")
      .group("up_ticker, up_mic")
      .having("COUNT(*) > 1")
      .to_a

    puts "Found #{duplicate_sets.size} duplicate groups."

    duplicate_sets.each_with_index do |set, idx|
      # Fetch duplicates ordered by creation; the first row becomes keeper
      duplicates_scope = Security
                           .where("UPPER(ticker) = ? AND COALESCE(UPPER(exchange_operating_mic), '') = ?",
                                  set.up_ticker, set.up_mic)
                           .order(:created_at)

      keeper = duplicates_scope.first
      next unless keeper

      duplicates = duplicates_scope.offset(1)

      dup_ids    = duplicates.ids

      # Skip if nothing to merge (defensive; shouldn't occur)
      next if dup_ids.empty?

      begin
        ActiveRecord::Base.transaction do
          # --------------------------------------------------------------
          # HOLDINGS
          # --------------------------------------------------------------
          holdings_moved   = 0
          holdings_deleted = 0

          dup_ids.each do |dup_id|
            Holding.where(security_id: dup_id).find_each(batch_size: 1_000) do |holding|
              # Will this holding collide with an existing keeper row?
              conflict_exists = Holding.where(
                account_id: holding.account_id,
                security_id: keeper.id,
                date:        holding.date,
                currency:    holding.currency
              ).exists?

              if conflict_exists
                holding.destroy!
                holdings_deleted += 1
              else
                holding.update!(security_id: keeper.id)
                holdings_moved += 1
              end
            end
          end

          # --------------------------------------------------------------
          # TRADES — no uniqueness constraints -> bulk update is fine
          # --------------------------------------------------------------
          trades_moved = Trade.where(security_id: dup_ids).update_all(security_id: keeper.id)

          # Ensure no rows remain pointing at duplicates before deletion
          raise "Leftover holdings detected" if Holding.where(security_id: dup_ids).exists?
          raise "Leftover trades detected"   if Trade.where(security_id: dup_ids).exists?

          duplicates.each(&:destroy!)   # destroys its security_prices via dependent: :destroy

          # Log inside the transaction so counters are in-scope
          total_holdings = holdings_moved + holdings_deleted
          puts "[#{idx + 1}/#{duplicate_sets.size}] Merged #{dup_ids.join(', ')} → #{keeper.id} " \
               "(#{total_holdings} holdings → #{holdings_moved} moved, #{holdings_deleted} removed, " \
               "#{trades_moved} trades)"
        end
      rescue => e
        puts "ERROR migrating #{dup_ids.join(', ')}: #{e.message}"
      end
    end

    puts "✅  Duplicate security migration complete."
  end

  desc "Migrate account valuation anchors"
  # 2025-07-10: Set opening_anchor kinds for valuations to support event-sourced ledger model.
  # Manual accounts get their oldest valuation marked as opening_anchor, which acts as the
  # starting balance for the account. Current anchors are only used for Plaid accounts.
  task migrate_account_valuation_anchors: :environment do
    puts "==> Migrating account valuation anchors..."

    manual_accounts = Account.manual.includes(valuations: :entry)
    total_accounts = manual_accounts.count
    accounts_processed = 0
    opening_anchors_set = 0

    manual_accounts.find_each do |account|
      accounts_processed += 1

      # Find oldest account entry
      oldest_entry = account.entries
                           .order("date ASC, created_at ASC")
                           .first

      # Check if it's a valuation that isn't already an anchor
      if oldest_entry && oldest_entry.valuation?
        derived_valuation_name = Valuation.build_opening_anchor_name(account.accountable_type)

        Account.transaction do
          oldest_entry.valuation.update!(kind: "opening_anchor")
          oldest_entry.update!(name: derived_valuation_name)
        end
        opening_anchors_set += 1
      end

      if accounts_processed % 100 == 0
        puts "[#{accounts_processed}/#{total_accounts}] Processed #{accounts_processed} accounts..."
      end
    rescue => e
      puts "ERROR processing account #{account.id}: #{e.message}"
    end

    puts "✅  Account valuation anchor migration complete."
    puts "    Processed: #{accounts_processed} accounts"
    puts "    Opening anchors set: #{opening_anchors_set}"
  end

  desc "Migrate balance components"
  # 2025-07-20: Migrate balance components to support event-sourced ledger model.
  # This task:
  #   1. Sets the flows_factor for each account based on the account's classification
  #   2. Sets the start_cash_balance, start_non_cash_balance, and start_balance for each balance
  #   3. Sets the cash_inflows, cash_outflows, non_cash_inflows, non_cash_outflows, net_market_flows, cash_adjustments, and non_cash_adjustments for each balance
  #   4. Sets the end_cash_balance, end_non_cash_balance, and end_balance for each balance
  task migrate_balance_components: :environment do
    puts "==> Migrating balance components..."

    BalanceComponentMigrator.run

    puts "✅  Balance component migration complete."
  end

  desc "Reconcile stored kinds of transfers into investment/crypto accounts"
  # 2026-10-08: older syncs and match paths left some legs of transfers into
  # investment/crypto accounts on a kind the current rules no longer give them
  # (see Transfer::InvestmentKindReconciler). Provider syncs only repair the
  # rows they replay. Idempotent; only transfer kinds are rewritten, standard
  # and one_time are left alone. Report totals for affected periods can change,
  # and reverting the code later does not restore the previous kinds.
  #
  #   DRY_RUN=1    print what would change without writing
  #   FAMILY_ID=id limit the run to one family
  task reconcile_investment_transfer_kinds: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV["DRY_RUN"]) || false
    scope = Transfer.all

    if ENV["FAMILY_ID"].present?
      family = Family.find_by(id: ENV["FAMILY_ID"])
      abort "No family with id #{ENV["FAMILY_ID"]}" unless family
      scope = scope.where(inflow_transaction_id: family.transactions.select(:id))
    end

    result = Transfer::InvestmentKindReconciler.new(scope: scope, dry_run: dry_run).run

    puts "#{dry_run ? "Dry run: " : ""}checked #{result.checked} transfers into investment/crypto accounts"
    if result.changed.empty?
      puts "No legs needed a new kind."
    else
      result.changed.each { |change, count| puts "  #{change}: #{count}" }
    end
  end
end
