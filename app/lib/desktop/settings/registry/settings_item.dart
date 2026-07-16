/// Whether a settings leaf drives real behavior today or is a reserved
/// placeholder shown as "coming soon".
enum SettingsAvailability {
  /// Wired to real behavior now.
  now,

  /// Reserved in the taxonomy; rendered disabled / "coming soon".
  comingSoon,
}

/// Search + navigation metadata for a single settings leaf.
///
/// Deliberately does NOT model the control kind: sections render their own
/// widgets (YAGNI). An item exists so the leaf is searchable (title / keywords
/// / help) and addressable by [id] within its section.
class SettingsItem {
  /// Creates an item descriptor.
  const SettingsItem({
    required this.id,
    required this.title,
    this.help = '',
    this.keywords = const [],
    this.availability = SettingsAvailability.now,
  });

  /// Stable identifier, unique within the app (convention: `section.leaf`).
  final String id;

  /// Human-readable title shown in search results.
  final String title;

  /// Tooltip / long description (requirement #7). Indexed for search.
  final String help;

  /// Extra search terms not present in [title]/[help].
  final List<String> keywords;

  /// Drives disabled / "coming soon" chrome.
  final SettingsAvailability availability;
}
