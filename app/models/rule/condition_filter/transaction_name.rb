class Rule::ConditionFilter::TransactionName < Rule::ConditionFilter
  # The name lives on entries, so the join has to exist before apply runs.
  #
  # @param scope [ActiveRecord::Relation] transactions the rule runs against
  # @return [ActiveRecord::Relation] the scope joined to entries
  def prepare(scope)
    scope.with_entry
  end

  # @param scope [ActiveRecord::Relation] the prepared scope
  # @param operator [String] one of the text operators this filter offers
  # @param value [String] the value the user wrote in the rule
  # @return [ActiveRecord::Relation] the scope narrowed to matching rows
  def apply(scope, operator, value)
    scope.where(build_sanitized_where_condition("entries.name", operator, value))
  end
end
