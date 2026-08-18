import 'package:flutter/widgets.dart';

import 'settings_item.dart';

/// Descriptor for one top-level settings section.
///
/// The [builder] returns the section's body widget, which lives in its own file
/// under `sections/`. Wave 2 agents flesh out those body widgets WITHOUT
/// editing the registry — the aggregator only references them.
class SettingsSection {
  /// Creates a section descriptor.
  const SettingsSection({
    required this.id,
    required this.title,
    required this.icon,
    required this.builder,
    this.items = const [],
    this.leading,
  });

  /// Stable identifier; also the value stored in `settings.lastSection`.
  final String id;

  /// Title shown in the nav pane and section header.
  final String title;

  /// Leading icon (a `PhosphorIcons.*` glyph from `phosphoricons_flutter`).
  final IconData icon;

  /// A leading widget that replaces [icon] when the section has a mark of its own
  /// — a repository's monogram (SPEC-per-repo-settings D15).
  ///
  /// Optional and additive rather than a widened `icon`: every app section is
  /// correctly described by a glyph, and only the generated per-repo sections need
  /// to be told apart from each other. [icon] stays required so a section can never
  /// end up with nothing to draw.
  final Widget? leading;

  /// Builds the section body widget.
  final WidgetBuilder builder;

  /// The section's leaves, used to build the search index.
  final List<SettingsItem> items;
}
