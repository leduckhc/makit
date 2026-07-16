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
  });

  /// Stable identifier; also the value stored in `settings.lastSection`.
  final String id;

  /// Title shown in the nav pane and section header.
  final String title;

  /// Leading icon (a `Symbols.*` glyph from `material_symbols_icons`).
  final IconData icon;

  /// Builds the section body widget.
  final WidgetBuilder builder;

  /// The section's leaves, used to build the search index.
  final List<SettingsItem> items;
}
