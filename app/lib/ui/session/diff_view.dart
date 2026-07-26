/// Diff-rendering widgets for tool detail views. Extracted from
/// `tool_renderers.dart` (SPEC-19).
///
/// - [DiffLineRow] colours a computed [DiffLine] (added/removed/context).
/// - [DiffText] colours diff text that already carries its own gutter markers
///   (the `edit` tool's `[path#HASH]` hashline result).
library;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'line_diff.dart';

/// One diff line: a coloured full-width row with a gutter prefix. Removed lines
/// use the error container, added lines a green wash, context stays muted.
class DiffLineRow extends StatelessWidget {
  const DiffLineRow({super.key, required this.line});
  final DiffLine line;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Lighter green text in dark mode so it clears 4.5:1 on the faint wash.
    final addedText = dark ? kDiffAdd.withValues(alpha: 0.8) : kDiffAdd;
    final (
      Color? background,
      Color textColor,
      String prefix,
    ) = switch (line.kind) {
      DiffKind.removed => (
        cs.errorContainer.withValues(alpha: 0.35),
        cs.error,
        '\u2212',
      ),
      DiffKind.added => (kDiffAdd.withValues(alpha: 0.15), addedText, '+'),
      DiffKind.context => (null, cs.onSurfaceVariant, ' '),
    };
    final style = Theme.of(
      context,
    ).textTheme.bodySmall?.mono.copyWith(color: textColor);
    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: kSpace8, vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 14, child: Text(prefix, style: style)),
          Expanded(child: SelectableText(line.text, style: style)),
        ],
      ),
    );
  }
}

/// Renders diff text that already carries its own gutter markers — the `edit`
/// tool's hashline result: a `[path#HASH]` header followed by `+`/`-`/context
/// rows (`+316:…`, `-136:…`, ` 139:…`). Each line gets a full-width colour wash
/// (green added, red removed, muted context, highlighted header) like a git
/// diff. Line numbers stay visible.
class DiffText extends StatelessWidget {
  const DiffText(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final lines = text.split('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final line in lines) _DiffTextLine(line: line)],
    );
  }
}

class _DiffTextLine extends StatelessWidget {
  const _DiffTextLine({required this.line});
  final String line;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Lighter green text in dark mode so it clears 4.5:1 on the faint wash.
    final addedText = dark ? kDiffAdd.withValues(alpha: 0.8) : kDiffAdd;
    final isHeader =
        line.startsWith('[') && line.contains('#') && line.endsWith(']');
    final (Color? background, Color textColor) = isHeader
        ? (cs.surfaceContainerHighest, cs.primary)
        : line.startsWith('+')
        ? (kDiffAdd.withValues(alpha: 0.15), addedText)
        : line.startsWith('-')
        ? (cs.errorContainer.withValues(alpha: 0.35), cs.error)
        : (null, cs.onSurfaceVariant);
    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: kSpace8, vertical: 1),
      child: SelectableText(
        line.isEmpty ? ' ' : line,
        style: Theme.of(context).textTheme.bodySmall?.mono.copyWith(
          color: textColor,
          fontWeight: isHeader ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
    );
  }
}
