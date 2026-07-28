import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// Fixed height for design-system popup-menu items: one step above the 16px
/// glyph so rows read compact (not the jumbo `ListTile` default).
const double kMenuItemHeight = 36;

/// A design-system [PopupMenuItem]: a [kMenuItemHeight] row with a 16px leading
/// glyph, a [kSpace8] gap, and a `bodyMedium` label. [color] tints both the
/// icon and the label (destructive/error actions); when null both inherit the
/// menu's default colors. [enabled] mirrors [PopupMenuItem.enabled].
///
/// Shared by every action menu (tab context menu, pane header, mobile session
/// and repo menus) so their sizing, spacing, and typography stay in lockstep.
PopupMenuItem<T> themedMenuItem<T>({
  required T value,
  required IconData icon,
  required String label,
  Color? color,
  bool enabled = true,
}) {
  return PopupMenuItem<T>(
    value: value,
    enabled: enabled,
    height: kMenuItemHeight,
    child: _MenuItemRow(icon: icon, label: label, color: color),
  );
}

class _MenuItemRow extends StatelessWidget {
  const _MenuItemRow({required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final bodyMedium = Theme.of(context).textTheme.bodyMedium;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: kSpace8),
        Flexible(
          child: Text(
            label,
            style: color == null
                ? bodyMedium
                : bodyMedium?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
