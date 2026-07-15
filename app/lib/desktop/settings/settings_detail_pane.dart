import 'package:flutter/material.dart';

import 'registry/settings_section.dart';

/// Right pane: renders the selected [section]'s body via its registry builder.
///
/// Wrapped in a [PageStorageKey] so each section keeps its own scroll offset
/// (best-effort restoration per SPEC-13 §C).
class SettingsDetailPane extends StatelessWidget {
  /// Creates the detail pane for [section].
  const SettingsDetailPane({required this.section, super.key});

  /// The section whose body is shown.
  final SettingsSection section;

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: PageStorageKey<String>('settings.section.${section.id}'),
      child: Builder(builder: section.builder),
    );
  }
}
