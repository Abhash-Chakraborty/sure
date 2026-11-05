require "test_helper"

class FamilyResetJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "resets family data successfully" do
    initial_account_count = @family.accounts.count
    initial_category_count = @family.categories.count
    import_session = @family.import_sessions.create!(expected_chunks: 1)
    import_session.imports.create!(
      family: @family,
      type: "SureImport",
      sequence: 1,
      checksum: "a" * 64
    )
    import_session.source_mappings.create!(
      family: @family,
      source_type: "Category",
      source_id: "source-category-1",
      target: @family.categories.first
    )

    # Family should have existing data
    assert initial_account_count > 0
    assert initial_category_count > 0
    assert_equal 1, @family.import_sessions.count
    assert_equal 1, @family.import_source_mappings.count

    FamilyResetJob.perform_now(@family)

    # All data should be removed
    assert_equal 0, @family.accounts.reload.count
    assert_equal 0, @family.categories.reload.count
    assert_equal 0, @family.import_sessions.reload.count
    assert_equal 0, @family.import_source_mappings.reload.count
    assert_equal 0, @family.imports.reload.count
  end

  test "reset leaves another family's imports and mappings untouched" do
    other_family = Family.create!(name: "Other Family", currency: "USD", locale: "en")
    other_category = other_family.categories.create!(name: "Other Category")
    other_session = other_family.import_sessions.create!(expected_chunks: 1)
    other_import = other_session.imports.create!(
      family: other_family,
      type: "SureImport",
      sequence: 1,
      checksum: "b" * 64
    )
    other_mapping = other_session.source_mappings.create!(
      family: other_family,
      source_type: "Category",
      source_id: "source-category-1",
      target: other_category
    )

    @family.import_sessions.create!(expected_chunks: 1)

    FamilyResetJob.perform_now(@family)

    assert ImportSession.exists?(other_session.id)
    assert Import.exists?(other_import.id)
    assert ImportSourceMapping.exists?(other_mapping.id)
    assert Category.exists?(other_category.id)
    assert_equal other_category, other_mapping.reload.target
  end
end
