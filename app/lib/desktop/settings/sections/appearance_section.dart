import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../prefs/preference_entries.dart';
import '../prefs/preferences_providers.dart';
import 'section_header.dart';

/// Appearance section body.
///
/// Wave 1 fully wires the **Theme** control (the one real leaf); the remaining
/// Appearance leaves (accent, text & code, layout, chat rendering) are
/// reserved placeholders for Wave 2.
class AppearanceSection extends StatelessWidget {
  /// Creates the Appearance section body.
  const AppearanceSection({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      children: [
        const SettingsSectionHeader(title: 'Appearance'),
        const _ThemeRow(),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
          child: Text(
            'Accent color, text & code, layout, and chat rendering are coming '
            'soon.',
            style: TextStyle(color: cs.outline, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

/// The Theme row: a System / Light / Dark segmented control that reads and
/// writes [themeModePreference], plus a per-row reset (↺) when it differs from
/// the default (System) — mirroring the keymap row's reset idiom.
class _ThemeRow extends ConsumerWidget {
  const _ThemeRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.preference(themeModePreference);
    final modified = ref.preferenceModified(themeModePreference);
    final controller = ref.read(preferencesControllerProvider.notifier);

    return ListTile(
      title: const Text('Theme'),
      subtitle: const Text('Match the system appearance, or force light/dark.'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SegmentedButton<ThemeMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text('System')),
              ButtonSegment(value: ThemeMode.light, label: Text('Light')),
              ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
            ],
            selected: {mode},
            onSelectionChanged: (selection) =>
                controller.set(themeModePreference, selection.first),
          ),
          const SizedBox(width: 8),
          if (modified)
            IconButton(
              tooltip: 'Reset to default',
              icon: const Icon(Symbols.settings_backup_restore, size: 18),
              onPressed: () => controller.reset(themeModePreference),
            )
          else
            const SizedBox(width: 40),
        ],
      ),
    );
  }
}
