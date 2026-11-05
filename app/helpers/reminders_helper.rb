module RemindersHelper
  # The sidebar entry for /reminders, with a count of what's overdue or due
  # today on its icon. Nil without a family, so it drops out of the
  # `Array#compact` nav list.
  def reminders_nav_item
    return nil if Current.family.nil?

    {
      name: t("layouts.application.nav.reminders"),
      path: reminders_path,
      icon: "bell",
      icon_custom: false,
      active: page_active?(reminders_path),
      badge: Current.family.reminders.needing_attention(Current.family.local_date).count
    }
  end
end
