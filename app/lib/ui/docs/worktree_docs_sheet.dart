/// SPEC-docs-scoping-and-board-rework D1/D2 — the docs sheet for one worktree,
/// the phone entry point that mirrors `showWorktreePortsSheet`. Tapping the
/// worktree row's docs glyph opens this sheet, which lists ONLY that worktree's
/// docs (mtime-descending, the honest set the badge counts). A row tap opens
/// the existing preview (SPEC-doc-preview D12). The sheet ends with one
/// deliberate widening row, `All docs in <repo>`, which opens the board scoped
/// to that repo \u2014 nothing auto-widens (D2).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/routes.dart';
import '../../app/theme.dart';
import '../../store/docs.dart';
import '../../store/store.dart';
import '../widgets/sheet_header.dart';
import 'doc_preview.dart';
import 'doc_row.dart';

/// Opens the worktree's docs sheet. The doc list is read inside the builder
/// behind a [Consumer] so a later `docs.snapshot` (a file written, renamed, or
/// removed) is reflected live \u2014 a one-shot `ref.read` at open time would strand
/// the sheet on stale data, the trap `showWorktreePortsSheet` documents.
Future<void> showWorktreeDocsSheet(
  BuildContext context, {
  required String worktreePath,
  required String branch,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetCtx) => SafeArea(
      child: Consumer(
        builder: (ctx, ref, _) {
          final docs = ref.watch(docsForWorktreeProvider(worktreePath));
          final located = ref.watch(reposProvider).locateWorktree(worktreePath);
          final repoId = located?.repo.id;
          return WorktreeDocsSheetBody(
            branch: branch,
            docs: docs,
            repoName: located?.repo.name,
            nowMs: DateTime.now().millisecondsSinceEpoch,
            // A second tap opens the existing preview widget (D1). It stacks on
            // this sheet exactly as the port detail sheet stacks on sheet 1.
            onOpenDoc: (doc) => showDocPreviewSheet(sheetCtx, doc),
            // Widen to the board, scoped to this repo (D2/D3). Pop the sheet
            // first so backing out of the board does not land on it \u2014 the
            // pop-then-go ordering `onOpenPortsScreen` uses.
            onOpenDocsBoard: repoId == null
                ? null
                : () {
                    Navigator.of(sheetCtx).pop();
                    sheetCtx.go('$kRouteDocs?repo=$repoId');
                  },
          );
        },
      ),
    ),
  );
}

/// The body of the docs sheet. Pure (data + callbacks in) so it is directly
/// pumpable, the same split as [WorktreePortsSheetBody].
class WorktreeDocsSheetBody extends StatelessWidget {
  const WorktreeDocsSheetBody({
    super.key,
    required this.branch,
    required this.docs,
    required this.onOpenDoc,
    this.repoName,
    this.onOpenDocsBoard,
    this.nowMs,
  });

  final String branch;
  final List<DocInfo> docs;
  final void Function(DocInfo doc) onOpenDoc;

  /// The owning repo's name, printed in the widening row. Null hides the row \u2014
  /// the pure body carries no navigation of its own.
  final String? repoName;

  /// Opens the board scoped to this repo (D2). When null the widening row is
  /// hidden, so an unlocatable worktree offers no dead link.
  final VoidCallback? onOpenDocsBoard;

  /// Injected clock so each row's "2 min ago" is deterministic in tests; falls
  /// back to the wall clock in production.
  final int? nowMs;

  @override
  Widget build(BuildContext context) {
    final referenceNowMs = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: 'Docs · $branch'),
          for (final doc in docs)
            DocRow(
              key: ValueKey('docs-sheet-row-${doc.key}'),
              doc: doc,
              nowMs: referenceNowMs,
              onTap: () => onOpenDoc(doc),
              pathStyle: DocPathStyle.relative,
            ),
          if (onOpenDocsBoard != null && repoName != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                kSpace16,
                kSpace8,
                kSpace16,
                0,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: onOpenDocsBoard,
                  icon: const Icon(PhosphorIconsLight.files, size: 16),
                  label: Text('All docs in $repoName'),
                ),
              ),
            ),
          const SizedBox(height: kSpace8),
        ],
      ),
    );
  }
}
