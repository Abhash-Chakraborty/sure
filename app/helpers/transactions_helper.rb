module TransactionsHelper
  # @param exclude [Array<String>] filter keys to leave out (e.g. the account
  #   tab doesn't apply to the account activity feed, which is already scoped
  #   to one account)
  # @return [Array<Hash>] the filters offered above the transaction list, each
  #   with the key its partial is named for, a translated label and an icon
  def transaction_search_filters(exclude: [])
    [
      { key: "account_filter", label: t("transactions.search.filters.account"), icon: "layers" },
      { key: "date_filter", label: t("transactions.search.filters.date"), icon: "calendar" },
      { key: "type_filter", label: t("transactions.search.filters.type"), icon: "tag" },
      { key: "status_filter", label: t("transactions.search.filters.status"), icon: "clock" },
      { key: "amount_filter", label: t("transactions.search.filters.amount"), icon: "hash" },
      { key: "category_filter", label: t("transactions.search.filters.category"), icon: "shapes" },
      { key: "tag_filter", label: t("transactions.search.filters.tag"), icon: "tags" },
      { key: "merchant_filter", label: t("transactions.search.filters.merchant"), icon: "store" },
      { key: "ai_filter", label: t("transactions.search.filters.ai"), icon: "sparkles" },
      { key: "attachment_filter", label: t("transactions.search.filters.attachment"), icon: "paperclip" }
    ].reject { |filter| exclude.include?(filter[:key]) }
  end

  # @param label [String] a stored investment_activity_label such as "Sweep In"
  # @return [String] its name in the current locale, or the label itself when
  #   it has no translation
  def investment_activity_label_name(label)
    t("transactions.activity_labels.#{label.parameterize(separator: "_")}", default: label)
  end

  # @param filter [Hash] one entry from transaction_search_filters
  # @return [String] the partial that renders that filter's controls
  def get_transaction_search_filter_partial_path(filter)
    "transactions/searches/filters/#{filter[:key]}"
  end

  # @return [Hash] the filter shown when the user has not picked one
  def get_default_transaction_search_filter
    transaction_search_filters[0]
  end

  # Shared between the transactions page and the account activity feed's
  # amount filter badge, so the label doesn't drift out of sync with the
  # options offered in filters/_amount_filter.html.erb.
  # @param operator [String, nil] "equal", "greater" or "less"
  # @return [String] the translated operator label
  def transaction_amount_operator_label(operator)
    case operator
    when "equal" then t("transactions.searches.search.equal_to")
    when "greater" then t("transactions.searches.search.greater_than")
    when "less" then t("transactions.searches.search.less_than")
    else operator.to_s
    end
  end

  # A split child is only folded under its parent when the user asked for
  # grouping and the current view is rendering grouped.
  #
  # @param entry [Entry] the entry being rendered
  # @param params_grouped [String, nil] the grouped param as it arrived
  # @return [Boolean] whether to render this entry inside its split group
  def in_split_group?(entry, params_grouped)
    entry.split_child? && Current.user.show_split_grouped? && params_grouped == "true"
  end

  # Files whose content shapes a cached transaction row; see
  # transaction_row_cache_key.
  TRANSACTION_ROW_SOURCES = %w[
    app/views/transactions/_transaction.html.erb
    app/views/transactions/_transaction_category.html.erb
    app/views/transactions/_transfer_match.html.erb
    app/views/categories/_*.html.erb
    app/views/tags/_*.html.erb
    app/views/investment_activity/_*.html.erb
    app/helpers/transactions_helper.rb
    app/helpers/categories_helper.rb
    app/components/DS/*.{rb,html.erb}
    config/locales/**/*.yml
  ].freeze

  TRANSACTION_ROW_SOURCES_DIGEST = Digest::SHA256.hexdigest(
    TRANSACTION_ROW_SOURCES.flat_map { |pattern| Dir[Rails.root.join(pattern).to_s] }.sort.map { |file| File.read(file) }.join
  ).first(16)

  # Fragment cache key for one row of the transactions list. Everything the
  # row shows or branches on is part of the key, so any change renders the
  # row fresh:
  #
  # - the records it reads (entry, transaction, tags, merchant, transfer and
  #   its other leg, whose kind and category an inflow row depends on, the
  #   security a brokerage activity shows a logo for)
  # - the displayed attributes of the accounts and categories it shows, and
  #   whether an account supports trades (a crypto account's subtype); their
  #   record versions would change on every balance sync or category pick
  # - per-user or per-request state (locale, user, family display settings,
  #   whether the user may annotate the account or see the counterpart,
  #   whether the entry is a split parent, grouped rendering, view context)
  # - a digest of the row's templates, the helpers and DS components it
  #   renders and the locale files (TRANSACTION_ROW_SOURCES), plus the image
  #   build or app version, so a deploy with new markup or translations never
  #   serves old rows, also for source builds without BUILD_COMMIT_SHA; skip_digest is on because the ERB
  #   dependency tracker cannot digest DS::* components (see
  #   account_sidebar_tabs)
  # - the Brandfetch settings that shape logo URLs
  #
  # Add a file to TRANSACTION_ROW_SOURCES when the row starts rendering it.
  def transaction_row_cache_key(entry, view_ctx:, in_split_group:)
    transaction = entry.entryable
    transfer = transaction.transfer
    outflow_leg = transaction.transfer_as_outflow.present?
    counterpart = transfer && (outflow_leg ? transfer.to_account : transfer.from_account)
    other_leg = transfer && (outflow_leg ? transfer.inflow_transaction : transfer.outflow_transaction)
    split_parent = @split_parent_entry_ids ? @split_parent_entry_ids.include?(entry.id) : entry.split_parent?
    account_key = ->(account) { account && [ account.id, account.name, account.accountable_type, account.supports_trades? ] }
    category_key = ->(category) { category && [ category.id, category.name, category.color, category.lucide_icon ] }

    [
      "transaction_row",
      TRANSACTION_ROW_SOURCES_DIGEST,
      ENV["BUILD_COMMIT_SHA"].presence || (@app_version ||= Sure.version.to_s),
      I18n.locale,
      Current.user&.id,
      Current.family&.currency,
      Current.family&.locale,
      view_ctx,
      in_split_group,
      split_parent,
      can_annotate_account?(entry.account),
      counterpart.present? && @accessible_account_ids&.include?(counterpart.id),
      Setting.brand_fetch_logo_size,
      Setting.brand_fetch_client_id.presence&.then { |id| Digest::SHA256.hexdigest(id) },
      entry.cache_key_with_version,
      transaction.cache_key_with_version,
      account_key.(entry.account),
      category_key.(transaction.category),
      transaction.merchant&.cache_key_with_version,
      transaction.tags.map(&:cache_key_with_version).sort,
      transfer&.cache_key_with_version,
      other_leg&.cache_key_with_version,
      account_key.(counterpart),
      (category_key.(other_leg.category) if transfer && !outflow_leg),
      transaction.activity_security&.cache_key_with_version
    ]
  end

  # Whether the current user may annotate (e.g. re-tag) entries on this
  # account. Memoized per request so list rows don't query per row.
  def can_annotate_account?(account)
    return false unless Current.user

    @annotatable_account_ids ||= Account.annotatable_by(Current.user).pluck(:id).to_set
    @annotatable_account_ids.include?(account.id)
  end

  # The dashboard drill-down filters by account id, so its filter chips name
  # the account rather than print the id. Memoized per request like the above.
  def transaction_filter_account_name(account_id)
    @transaction_filter_account_names ||= Current.user.accessible_accounts.pluck(:id, :name).to_h
    @transaction_filter_account_names.fetch(account_id, account_id)
  end

  # ---- Transaction extra details helpers ----
  # Returns a hash describing extra details for a transaction, or nil when it
  # has none. Input can be a Transaction or an Entry (responds_to :transaction).
  # Structure:
  #   {
  #     kind: :raw,
  #     provider_extras: [],
  #     raw: String (pretty JSON)
  #   }
  def build_transaction_extra_details(obj)
    tx = obj.respond_to?(:transaction) ? obj.transaction : obj
    return nil unless tx.respond_to?(:extra) && tx.extra.present?

    {
      kind: :raw,
      provider_extras: [],
      raw: pretty_json(tx.extra)
    }
  end

  # Provider payloads are arbitrary JSON, so anything that cannot be generated
  # falls back to its string form rather than raising in a view.
  #
  # @param value [Object] any provider value
  # @return [String] indented JSON, or the value's string form
  def pretty_json(value)
    JSON.pretty_generate(value)
  rescue StandardError
    value.to_s
  end
end
