/// Notifications section body (SPEC-13 migration map).
///
/// Desktop is the control surface, so the one real knob today is the
/// **reminder delay**: how long an unanswered server request stays on-screen
/// before the desktop nudges with a system notification. It is a stored
/// preference read reactively by `desktop_app.dart`. Per-type mute / approval
/// reminders are a reserved `[future]` placeholder.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../prefs/preference_entries.dart';
import '../prefs/preferences_providers.dart';
import 'section_header.dart';
import 'settings_group.dart';
import 'coming_soon.dart';

/// The reminder-delay choices offered in the dropdown, in whole minutes.
const List<int> kReminderDelayChoicesMinutes = [1, 2, 5, 10];

/// Notifications section body: the reminder-delay control plus a reserved
/// per-type mute placeholder.
class NotificationsSection extends StatelessWidget {
  /// Creates the Notifications section body.
  const NotificationsSection({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: const [
        SettingsSectionHeader(title: 'Notifications'),
        SettingsGroup(
          children: [
            _ReminderDelayRow(),
            ComingSoonRow(
              icon: Symbols.notifications_off,
              title: 'Per-type mute & approval reminders',
              subtitle:
                  'Mute specific notification types; approval '
                  'reminders.',
            ),
          ],
        ),
      ],
    );
  }
}

/// Reminder delay: a dropdown of minute choices that reads and writes
/// [notificationsReminderDelayPreference], with a per-row reset (↺) and a
/// "Modified" tag when it differs from the default — mirroring the Theme row.
class _ReminderDelayRow extends ConsumerWidget {
  const _ReminderDelayRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final minutes = ref.preference(notificationsReminderDelayPreference);
    final modified = ref.preferenceModified(
      notificationsReminderDelayPreference,
    );
    final controller = ref.read(preferencesControllerProvider.notifier);

    // Guard against a stale/foreign stored value: always render a valid choice.
    final choices = {...kReminderDelayChoicesMinutes, minutes}.toList()..sort();

    return ListTile(
      leading: Icon(Symbols.schedule, weight: 200, color: cs.outline),
      title: const Text('Reminder delay'),
      subtitle: const Text(
        'How long an unanswered request stays on screen before a system '
        'notification nudges you.',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (modified)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                'Modified',
                style: TextStyle(color: cs.primary, fontSize: 12),
              ),
            ),
          DropdownButton<int>(
            value: minutes,
            underline: const SizedBox.shrink(),
            onChanged: (value) {
              if (value == null) return;
              controller.set(notificationsReminderDelayPreference, value);
            },
            items: [
              for (final m in choices)
                DropdownMenuItem(value: m, child: Text(_minuteLabel(m))),
            ],
          ),
          const SizedBox(width: 8),
          if (modified)
            IconButton(
              tooltip: 'Reset to default',
              icon: const Icon(
                Symbols.settings_backup_restore,
                weight: 200,
                size: 18,
              ),
              onPressed: () =>
                  controller.reset(notificationsReminderDelayPreference),
            )
          else
            const SizedBox(width: 40),
        ],
      ),
    );
  }

  static String _minuteLabel(int minutes) =>
      minutes == 1 ? '1 minute' : '$minutes minutes';
}
