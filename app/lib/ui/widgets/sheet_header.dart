import 'package:flutter/material.dart';

/// A consistent header for list-style modal bottom sheets: a bold title plus
/// an explicit close (✕) button that dismisses the sheet. Pair with
/// `showDragHandle: true` so users always have a discoverable way to back out
/// of a list without making a selection.
class SheetHeader extends StatelessWidget {
  const SheetHeader({super.key, required this.title});

  final String title;

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
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}
