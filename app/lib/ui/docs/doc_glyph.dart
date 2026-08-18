/// The worktree-row docs glyph (SPEC-doc-preview, mockup Card 2 right frame): a
/// trailing-column file icon in the slot next to the ports plug. Renders
/// nothing when the worktree owns no docs, so a quiet branch adds no weight —
/// the same discipline as `ports_glyph.dart`.
library;

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

/// The presentational docs glyph. Pure: count in, pixels out; interaction
/// (hover popover / tap) is wired by the mounts, so it is shared byte-for-byte
/// between phone and desktop and testable on its own.
class DocsGlyph extends StatelessWidget {
  const DocsGlyph({super.key, required this.count, this.size = 16});

  /// Docs owned by this worktree — the number the semantics label speaks.
  final int count;

  /// Painted glyph size. 14 on the desktop sub-row, 16 on the phone column.
  final double size;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final label = count == 1 ? '1 doc' : '$count docs';
    return Semantics(
      label: label,
      child: SizedBox(
        width: size,
        height: size,
        child: Icon(
          PhosphorIconsLight.fileText,
          size: size,
          color: cs.onSurfaceVariant,
        ),
      ),
    );
  }
}
