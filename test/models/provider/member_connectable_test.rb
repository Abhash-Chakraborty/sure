require "test_helper"

class Provider::MemberConnectableTest < ActiveSupport::TestCase
  test "an adapter that declares no item class is not member connectable" do
    # The fail-closed default: every provider that has not been classified
    # behaves exactly as it does today.
    assert_nil Provider::Base.connection_item_class
    assert_not Provider::Base.member_connectable?
  end

  test "no adapter is member connectable without declaring per_connection" do
    Provider::Factory.registered_adapters.each do |adapter|
      next unless adapter.member_connectable?

      item_class = adapter.connection_item_class
      assert_equal :per_connection, item_class.declared_credential_scope,
        "#{adapter.name} is member-connectable but #{item_class} does not declare per_connection"
    end
  end

end
