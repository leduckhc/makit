import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'section_header.dart';

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
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSectionHeader(title: title),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Row(
            children: [
              Icon(Symbols.schedule, weight: 200, size: 18, color: cs.outline),
              const SizedBox(width: 8),
              Text(
                detail ?? 'Coming soon',
                style: TextStyle(color: cs.outline),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
