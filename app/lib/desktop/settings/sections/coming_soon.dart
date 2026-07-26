import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../../app/theme.dart';

import 'section_header.dart';
import 'settings_group.dart';

/// A disabled settings row with a trailing "Coming soon" tag, for reserved
/// `[future]` leaves. The single shared widget behind what were four
/// copy-pasted rows (`_ComingSoonRow`, `_TelemetryRow`, `_PerTypeMuteRow`).
class ComingSoonRow extends StatelessWidget {
  const ComingSoonRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      enabled: false,
      leading: Icon(icon, color: cs.outline),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(PhosphorIconsLight.clock, size: 16, color: cs.outline),
          const SizedBox(width: kSpace6),
          Text(
            'Coming soon',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.outline),
          ),
        ],
      ),
    );
  }
}

/// Placeholder body for an unimplemented section (and for `[future]` leaves).
///
/// Renders the section title header plus a muted "Coming soon" note. Wave 2
/// agents replace the whole section body widget that hosts this with real
/// controls — no registry edit required.
class ComingSoon extends StatelessWidget {
  /// Creates a placeholder for [title]. [detail] overrides the default note.
  const ComingSoon({required this.title, this.detail, super.key});

  /// The section title, shown in the header.
  final String title;

  /// Optional custom note; defaults to a generic "coming soon" line.
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionHeader(title: title),
        SettingsGroup(
          children: [
            ListTile(
              leading: Icon(
                PhosphorIconsLight.clock,
                size: 18,
                color: cs.outline,
              ),
              title: Text(
                detail ?? 'Coming soon',
                style: TextStyle(color: cs.outline),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
