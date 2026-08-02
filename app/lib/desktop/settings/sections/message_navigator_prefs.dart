/// The `Message navigator` settings leaf (SPEC-34): the rail's on/off switch and
/// its options.
///
/// One affordance, so one switch — the rail's options are shown only while it is
/// on, because a control that cannot affect anything is noise.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../ui/session/navigator/navigator_style.dart';
import '../../../store/prefs/preference.dart';
import '../../../store/prefs/preference_entries.dart';
import '../../../store/prefs/preferences_providers.dart';
import 'section_header.dart';
import 'settings_group.dart';

/// The subsection: header, blurb, and the rail's controls.
class MessageNavigatorPrefs extends ConsumerWidget {
  /// Creates the `Message navigator` settings leaf.
  const MessageNavigatorPrefs({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on =
        ref.preference(messageNavigatorStylePreference) ==
        MessageNavigatorStyle.rail;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsSectionHeader(title: 'Message navigator'),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'How you jump back to your own messages in a long transcript.',
          ),
        ),
        SettingsGroup(
          children: [
            SwitchListTile(
              value: on,
              title: const Text('Ripple rail'),
              subtitle: const Text(
                'A cosy cluster of ticks in the top-right corner — one per '
                'message you sent. Hover to ripple and reveal, click to jump.',
              ),
              onChanged: (next) => ref
                  .read(preferencesControllerProvider.notifier)
                  .set(
                    messageNavigatorStylePreference,
                    next
                        ? MessageNavigatorStyle.rail
                        : MessageNavigatorStyle.off,
                  ),
            ),
            // Only built while the rail is on — not built-and-hidden.
            if (on) ...const [
              _SpacingRow(),
              _SwitchRow(
                entry: railRipplePreference,
                title: 'Ripple on hover',
                subtitle: 'Neighbouring ticks stretch and spread apart',
              ),
              _SwitchRow(
                entry: railEncodeLengthPreference,
                title: 'Tick length shows message length',
                subtitle: 'Makes the rail a fingerprint of the session',
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// Tick spacing: the one number a user notices immediately.
class _SpacingRow extends ConsumerWidget {
  const _SpacingRow();

  static const Map<int, String> _labels = {
    6: 'cosy',
    10: 'normal',
    14: 'roomy',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.preference(railTickSpacingPreference);
    return Padding(
      padding: const EdgeInsets.fromLTRB(56, 0, 16, kSpace12),
      child: Row(
        children: [
          const Expanded(child: Text('Tick spacing')),
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [
              for (final entry in _labels.entries)
                ButtonSegment(value: entry.key, label: Text(entry.value)),
            ],
            selected: {_labels.containsKey(value) ? value : 6},
            onSelectionChanged: (selection) => ref
                .read(preferencesControllerProvider.notifier)
                .set(railTickSpacingPreference, selection.first),
          ),
        ],
      ),
    );
  }
}

/// A boolean option row bound to [entry].
class _SwitchRow extends ConsumerWidget {
  const _SwitchRow({
    required this.entry,
    required this.title,
    required this.subtitle,
  });

  final PreferenceEntry<bool> entry;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.preference(entry);
    return Padding(
      padding: const EdgeInsets.only(left: 40),
      child: SwitchListTile(
        value: value,
        title: Text(title),
        subtitle: Text(subtitle),
        onChanged: (next) =>
            ref.read(preferencesControllerProvider.notifier).set(entry, next),
      ),
    );
  }
}
