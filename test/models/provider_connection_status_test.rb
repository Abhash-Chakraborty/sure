# frozen_string_literal: true

require "test_helper"

class ProviderConnectionStatusTest < ActiveSupport::TestCase
  test "provider registry covers syncable family provider item associations" do
    expected_registry = Family.reflect_on_all_associations(:has_many).filter_map do |association|
      next unless association.name.to_s.end_with?("_items")
      next unless association.klass.included_modules.include?(Syncable)

      { association: association.name, type: association.klass.name }
    end

    registered_registry = ProviderConnectionStatus::PROVIDERS.map do |provider|
      { association: provider[:association], type: provider[:type] }
    end

    assert_equal expected_registry.sort_by { |entry| entry[:association].to_s },
                 registered_registry.sort_by { |entry| entry[:association].to_s }
  end

end
