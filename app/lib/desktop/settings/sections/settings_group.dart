import 'package:flutter/material.dart';

import '../../../app/theme.dart';

/// Groups the rows that sit under a [SettingsSectionHeader] into one rounded,
/// filled card so they read as a single unit (the macOS System Settings / iOS
/// grouped-list idiom). Use it between subsection headers in a section body:
///
/// ```dart
/// SettingsSectionHeader(title: 'Server'),
/// SettingsGroup(children: [_EndpointRow(), _LifecycleRow()]),
/// ```
///
/// The card's horizontal margin also indents the item rows relative to the
/// (flush-left) subsection titles, so no separate item inset is needed.
class SettingsGroup extends StatelessWidget {
  /// Creates a group card around [children] (one row each).
  const SettingsGroup({required this.children, super.key});

  /// The rows to box together, top to bottom. A hairline divider is drawn
  /// between adjacent rows.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Material(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(kRadius12),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const Divider(height: 1),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}
