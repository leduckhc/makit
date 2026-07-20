import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

/// A consistent header for list-style modal bottom sheets: a bold title plus
/// an explicit close (✕) button that dismisses the sheet. Pair with
/// `showDragHandle: true` so users always have a discoverable way to back out
/// of a list without making a selection.
class SheetHeader extends StatelessWidget {
  const SheetHeader({super.key, required this.title, this.actions});

  final String title;

  /// Optional widget(s) placed just before the close button — e.g. a search
  /// toggle for list sheets. Null by default so the header is just title + ✕.
  final Widget? actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          ?actions,
          IconButton(
            icon: const Icon(PhosphorIconsLight.x),
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}
