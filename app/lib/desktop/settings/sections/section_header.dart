import 'package:flutter/material.dart';

/// A section header matching the desktop settings idiom (see the keymap
/// screen's `_ScopeHeader`): UPPERCASE, 12px, w700, letterSpacing 0.8, colored
/// with the accent (`colorScheme.primary`). An optional [hint] renders muted
/// beneath it.
class SettingsSectionHeader extends StatelessWidget {
  /// Creates a header for [title].
  const SettingsSectionHeader({required this.title, this.hint, super.key});

  /// The section (or subsection) title. Rendered uppercase.
  final String title;

  /// Optional muted one-line description under the title.
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: cs.primary,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          if (hint != null)
            Text(
              hint!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.outline),
            ),
        ],
      ),
    );
  }
}
