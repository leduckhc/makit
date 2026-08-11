import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../status/status_event.dart';
import '../../status/status_providers.dart';
import '../../store/models.dart';
import '../../store/store.dart';
import '../widgets/lands_in_picker.dart';
import '../widgets/sheet_header.dart';

/// Whether [w]'s branch can be renamed. Mirrors the desktop sidebar's guards:
/// the primary checkout is the repo itself, a detached worktree has no branch to
/// rename, and renaming out from under an open PR would orphan the PR's head.
bool canRenameWorktree(Worktree w) =>
    !w.isPrimary && w.branch != null && w.pr?.state.toUpperCase() != 'OPEN';

/// Whether [w]'s target — the branch its work lands in — can be changed.
///
/// Same two exclusions as rename (the primary checkout *is* where branches
/// land; a detached worktree has no branch to land), but pointedly NOT gated on
/// an open PR the way [canRenameWorktree] is. Renaming out from under a PR
/// orphans its head, so that stays blocked — but retargeting an open PR is a
/// first-class operation (`gh pr edit --base`), so an open PR must leave this
/// enabled. The asymmetry is deliberate.
bool canRetargetWorktree(Worktree w) => !w.isPrimary && w.branch != null;

/// Whether [w] can be deleted. Everything but the primary checkout — deleting
/// that would take the repo with it.
bool canDeleteWorktree(Worktree w) => !w.isPrimary;

/// Worktree actions for the mobile home (SPEC-11 parity with the sidebar's row
/// menu). Opened by long-pressing the row: a tap already folds the row, and a
/// second always-visible overflow button would crowd a line that already carries
/// the branch, star, diff chip and PR pill.
///
/// Guarded actions stay *visible but disabled*, as on desktop, so the action's
/// absence is never mistaken for the feature missing.
Future<void> showWorktreeActions(
  BuildContext context,
  WidgetRef ref, {
  required RepoInfo repo,
  required Worktree worktree,
}) async {
  // Renamed locally: the builder below shadows this with the LIVE value, and two
  // identifiers one letter apart would be an easy way to reintroduce the bug.
  final w = worktree;
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      final cs = Theme.of(sheetContext).colorScheme;
      // Re-derive from the snapshot instead of closing over the `worktree` we were
      // handed. Tapping "Lands in" pops this sheet before the picker opens, so the
      // obvious staleness path is already closed — but a snapshot can also arrive
      // while the sheet sits open (the agent commits, another client retargets), and
      // then the target and guards printed here would describe a state that no
      // longer exists. Falls back to the passed-in value for a worktree the snapshot
      // no longer carries, so a removal cannot blank the sheet mid-tap.
      final worktree =
          ref.watch(reposProvider).locateWorktree(w.path)?.worktree ?? w;
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetHeader(title: worktree.branch ?? 'detached'),
              // Under the header so the sheet says, at a glance, where this branch
              // lands. The header already IS the branch, so the source half is
              // omitted — printing it twice would just waste the line. Only shown
              // when there is a branch that lands (i.e. the retarget guard holds).
              if (canRetargetWorktree(worktree))
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: LandsInLine(
                    targetBranch: worktree.targetBranch,
                    targetResolved: worktree.targetResolved,
                  ),
                ),
              ListTile(
                enabled: canRenameWorktree(worktree),
                leading: const Icon(PhosphorIconsLight.textAa),
                title: const Text('Rename branch'),
                subtitle: canRenameWorktree(worktree)
                    ? null
                    : Text(_renameBlockedReason(worktree)),
                onTap: () => Navigator.pop(sheetContext, 'rename'),
              ),
              // Between Rename and Delete: like Rename it is a non-destructive
              // branch property, so the two are siblings and the destructive
              // Delete stays last.
              ListTile(
                enabled: canRetargetWorktree(worktree),
                leading: const Icon(kLandsInIcon),
                title: const Text('Lands in'),
                // Enabled: the current target (so the row states today's value).
                // Disabled: why, following the same visible-but-disabled
                // convention as Rename.
                subtitle: canRetargetWorktree(worktree)
                    ? (worktree.targetBranch == null
                          ? null
                          : Text(worktree.targetBranch!))
                    : Text(_landsInBlockedReason(worktree)),
                onTap: () => Navigator.pop(sheetContext, 'landsIn'),
              ),
              ListTile(
                enabled: canDeleteWorktree(worktree),
                leading: Icon(PhosphorIconsLight.trash, color: cs.error),
                title: Text(
                  'Delete worktree',
                  style: TextStyle(color: cs.error),
                ),
                subtitle: canDeleteWorktree(worktree)
                    ? null
                    : const Text('The primary checkout cannot be removed'),
                onTap: () => Navigator.pop(sheetContext, 'delete'),
              ),
            ],
          ),
        ),
      );
    },
  );
  if (action == null || !context.mounted) return;
  switch (action) {
    case 'rename':
      await _renameBranch(context, ref, repo: repo, worktree: worktree);
    case 'landsIn':
      // `sheet: true`: on touch the picker is a bottom sheet, matching the
      // surface it was launched from. It persists the choice itself.
      await showLandsInPicker(
        context,
        ref,
        projectId: repo.id,
        worktree: worktree,
        sheet: true,
      );
    case 'delete':
      await _deleteWorktree(context, ref, repo: repo, worktree: worktree);
  }
}

/// Why "Lands in" is disabled — shown under the greyed row like the rename
/// reason. No open-PR case here on purpose: an open PR does not block
/// retargeting (see [canRetargetWorktree]).
String _landsInBlockedReason(Worktree w) {
  if (w.isPrimary) return 'This is where branches land, not one that lands';
  return 'This worktree has no branch to land';
}

/// Why "Rename branch" is disabled — shown under the greyed row so the block is
/// explained rather than just enforced.
String _renameBlockedReason(Worktree w) {
  if (w.isPrimary) return 'The primary checkout keeps the repo branch';
  if (w.branch == null) return 'This worktree has no branch';
  return 'Its pull request is still open';
}

Future<void> _renameBranch(
  BuildContext context,
  WidgetRef ref, {
  required RepoInfo repo,
  required Worktree worktree,
}) async {
  // Resolved before the first await: `ref` throws once its widget is
  // unmounted, and the record must survive the thing that reported to it.
  final status = ref.status;
  final newName = await showDialog<String>(
    context: context,
    builder: (_) => _RenameBranchDialog(initial: worktree.branch ?? ''),
  );
  if (newName == null || newName.isEmpty || newName == worktree.branch) return;
  try {
    await ref
        .read(storeControllerProvider.notifier)
        .renameBranch(repo.id, worktree.path, newName);
  } catch (e) {
    status.failure(
      'Could not rename branch',
      error: e,
      source: StatusSources.worktree,
    );
  }
}

Future<void> _deleteWorktree(
  BuildContext context,
  WidgetRef ref, {
  required RepoInfo repo,
  required Worktree worktree,
}) async {
  // Resolved before the first await: `ref` throws once its widget is
  // unmounted, and the record must survive the thing that reported to it.
  final status = ref.status;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dctx) => AlertDialog(
      title: const Text('Delete worktree'),
      content: Text(
        'Delete the worktree for "${worktree.branch ?? worktree.path}"? '
        'Uncommitted changes will be lost and any running sessions in it will '
        'be stopped.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dctx, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  try {
    await ref
        .read(storeControllerProvider.notifier)
        .removeWorktree(repo.id, worktree.path);
  } catch (e) {
    status.failure(
      'Could not delete worktree',
      error: e,
      source: StatusSources.worktree,
    );
  }
}

/// Rename prompt. Owns its controller as State so it outlives the route's exit
/// animation (which still rebuilds the field).
class _RenameBranchDialog extends StatefulWidget {
  const _RenameBranchDialog({required this.initial});

  final String initial;

  @override
  State<_RenameBranchDialog> createState() => _RenameBranchDialogState();
}

class _RenameBranchDialogState extends State<_RenameBranchDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename branch'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'New branch name'),
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Rename'),
        ),
      ],
    );
  }
}
