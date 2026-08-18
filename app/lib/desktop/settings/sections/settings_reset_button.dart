import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

/// A "reset to default" icon button for a settings row (SPEC-decomposition-and-dedup shared widget).
///
/// When [visible] is false it collapses to a fixed-width [SizedBox] so the row
/// beside it stays vertically aligned with rows whose value is unchanged. This
/// is the single widget behind the copy-pasted reset buttons that lived inline
/// in the theme, shortcuts, notifications, and endpoint rows.
class SettingsResetButton extends StatelessWidget {
  const SettingsResetButton({
    required this.visible,
    required this.onPressed,
    super.key,
  });

  final bool visible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox(width: 40);
    return IconButton(
      tooltip: 'Reset to default',
      icon: const Icon(PhosphorIconsLight.clockCounterClockwise, size: 18),
      onPressed: onPressed,
    );
  }
}
