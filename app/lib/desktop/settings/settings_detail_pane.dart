import 'package:flutter/material.dart';

import 'registry/settings_section.dart';

/// Max width of the settings detail content. On a wide window the section body
/// would otherwise stretch uncomfortably far; this caps it and centers the
/// column (macOS System Settings idiom).
const double kSettingsDetailMaxWidth = 720;

/// Right pane: renders the selected [section]'s body via its registry builder.
///
/// Wrapped in a [PageStorageKey] so each section keeps its own scroll offset
/// (best-effort restoration per SPEC-13 §C). The body is capped at
/// [kSettingsDetailMaxWidth] and centered so it doesn't span an overly wide
/// window.
class SettingsDetailPane extends StatelessWidget {
  /// Creates the detail pane for [section].
  const SettingsDetailPane({required this.section, super.key});

  /// The section whose body is shown.
  final SettingsSection section;

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: PageStorageKey<String>('settings.section.${section.id}'),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kSettingsDetailMaxWidth),
          child: Builder(builder: section.builder),
        ),
      ),
    );
  }
}
