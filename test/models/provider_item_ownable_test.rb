require "test_helper"

class ProviderItemOwnableTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @admin  = users(:family_admin)
    @member = users(:family_member)
    Current.reset
  end

  teardown { Current.reset }

  # An anonymous model that includes the concern without declaring a scope,
  # standing in for any of the 24 providers that have not been classified yet.
  def undeclared_item_class
    Class.new(ApplicationRecord) do
      self.table_name = "plaid_items"
      belongs_to :family
      include ProviderItemOwnable

      def self.name = "UndeclaredItem"
    end
  end

  # The same stand-in declared per_connection, like a member-connectable provider.
  def per_connection_item_class
    Class.new(ApplicationRecord) do
      self.table_name = "plaid_items"
      belongs_to :family
      include ProviderItemOwnable
      credential_scope :per_connection

      def self.name = "PerConnectionItem"
    end
  end

  def build_item(**attributes)
    per_connection_item_class.new(family: @family, name: "Member Bank", plaid_id: "item_#{SecureRandom.hex(4)}", access_token: "token", **attributes)
  end

  test "credential scope defaults to tenant_wide so an unclassified provider stays admin-only" do
    klass = undeclared_item_class

    assert_equal :tenant_wide, klass.declared_credential_scope
    assert_not klass.member_connectable?
  end

  test "credential scope rejects an unknown value" do
    error = assert_raises(ArgumentError) { undeclared_item_class.credential_scope(:sometimes) }
    assert_match(/unknown credential scope/, error.message)
  end

  test "a per_connection declaration makes the item member connectable" do
    assert_equal :per_connection, per_connection_item_class.declared_credential_scope
    assert per_connection_item_class.member_connectable?
  end

  test "owner defaults to the current user" do
    Current.session = @member.sessions.create!

    item = build_item
    item.save!

    assert_equal @member, item.owner
  end

  test "owner falls back to a family admin when there is no current user" do
    item = build_item
    item.save!

    assert_equal @admin, item.owner
  end

  test "owner must belong to the same family" do
    outsider = users(:empty)

    item = build_item(owner: outsider)

    assert_not item.valid?
    assert_includes item.errors[:owner], "is invalid"
  end

  test "an admin may manage any connection in the family" do
    item = build_item(owner: @member)

    assert item.manageable_by?(@admin)
  end

  test "a member may manage a per_connection item they own" do
    item = build_item(owner: @member)

    assert item.manageable_by?(@member)
  end

  test "a member may not manage a connection owned by someone else" do
    item = build_item(owner: @admin)

    assert_not item.manageable_by?(@member)
  end

  test "manageable_by? is false without a user" do
    assert_not build_item.manageable_by?(nil)
  end
end
