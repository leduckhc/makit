/// SPEC-46 Card 2 — the doc row, shared by the screen, the sheet and the
/// popover (one row, many surfaces — the mockup's rule 2).
///
/// Layout: a leading kind glyph (html warm / md cool), the **extracted** title
/// (D4, never the filename), the full path truncated from the LEFT, then a chip
/// line: kind, changed, docStatus badge, and `size · relative mtime`.
library;

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/docs.dart';
import 'doc_vocabulary.dart';

/// The full filesystem path of [doc] — `worktreePath` joined to `relPath`.
///
/// `relPath` alone is useless for a root-level file, where it just repeats the
/// title (`Notes` / `NOTES.md`) and says nothing about where the file is.
String docFullPath(DocInfo doc) {
  final root = doc.worktreePath.endsWith('/')
      ? doc.worktreePath.substring(0, doc.worktreePath.length - 1)
      : doc.worktreePath;
  return '$root/${doc.relPath}';
}

/// The "changed on this branch" chip (D5), keyed so a test asserts presence
/// without depending on colour.
const Key kDocChangedChip = ValueKey('doc-changed-chip');

/// The docStatus badge (D14), keyed for tests.
const Key kDocStatusBadge = ValueKey('doc-status-badge');

/// One tappable document row. Pure (data in, no provider read) so it is
/// directly pumpable and identical in every container.
class DocRow extends StatelessWidget {
  const DocRow({
    super.key,
    required this.doc,
    required this.nowMs,
    required this.onTap,
    this.selected = false,
  });

  final DocInfo doc;

  /// Injected clock so "2 min ago" is deterministic in tests.
  final int nowMs;
  final VoidCallback onTap;

  /// Highlights the row in the desktop popover's selected state (mockup Card 2
  /// right frame `.doc.sel`).
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? cs.surfaceContainerLow : null,
        padding: const EdgeInsets.fromLTRB(
          kSpace12,
          kSpace10,
          kSpace12,
          kSpace10,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: kSpace2),
              child: Icon(
                doc.kind == DocKind.html
                    ? PhosphorIconsLight.code
                    : PhosphorIconsLight.fileText,
                size: 18,
                color: docKindColor(doc.kind),
              ),
            ),
            const SizedBox(width: kSpace10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    doc.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: kSpace2),
                  // Truncate from the LEFT: the filename is the identifying
                  // part, so `…/learning-records/0006-layout.md` beats
                  // `/Users/le/Work/teachme/flutter/learning-…`. An RTL
                  // paragraph puts the ellipsis at the visual start; the path
                  // itself is wrapped in an LTR isolate so its leading `/` and
                  // separators cannot be reordered to the wrong end.
                  Directionality(
                    textDirection: TextDirection.rtl,
                    child: Text(
                      '\u2066${docFullPath(doc)}\u2069',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontFamily: kMonoFontFamily,
                      ),
                    ),
                  ),
                  const SizedBox(height: kSpace6),
                  Wrap(
                    spacing: kSpace6,
                    runSpacing: kSpace4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _KindChip(kind: doc.kind),
                      if (doc.changed == true)
                        const _ChangedChip(key: kDocChangedChip),
                      if (doc.docStatus != null)
                        _StatusBadge(
                          key: kDocStatusBadge,
                          status: doc.docStatus!,
                        ),
                      Text(
                        '${docSizeLabel(doc.bytes)} · '
                        '${docRelativeTime(doc.modifiedAt, nowMs: nowMs)}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: kSpace6),
            Icon(PhosphorIconsLight.caretRight, size: 16, color: cs.outline),
          ],
        ),
      ),
    );
  }
}

/// A tinted pill in the kind's accent (mockup `.chip.kind-html/.kind-md`).
class _KindChip extends StatelessWidget {
  const _KindChip({required this.kind});
  final DocKind kind;

  @override
  Widget build(BuildContext context) {
    final color = docKindColor(kind);
    return _Pill(
      label: docKindLabel(kind),
      fill: color.withValues(alpha: 0.14),
      text: color,
    );
  }
}

/// The "changed on this branch" chip (D5). The frozen `DocDTO` carries only a
/// boolean `changed`, so this is one honest chip — a "new vs modified" split
/// would need the untracked/modified distinction the wire does not provide.
class _ChangedChip extends StatelessWidget {
  const _ChangedChip({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _Pill(
      label: 'changed',
      fill: kStatusWarning.withValues(alpha: 0.14),
      text: cs.statusWarningText,
    );
  }
}

/// The docStatus badge (D14): `draft` amber, `implemented` green, else neutral.
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({super.key, required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tone = docStatusTone(cs, status);
    return _Pill(
      label: docStatusLabel(status),
      fill: tone.fill,
      text: tone.text,
    );
  }
}

/// The shared chip shape used across the doc row.
class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.fill, required this.text});

  final String label;
  final Color fill;
  final Color text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: kSpace8, vertical: 2),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(kRadius8),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelXs?.copyWith(
          color: text,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.1,
        ),
      ),
    );
  }
}
