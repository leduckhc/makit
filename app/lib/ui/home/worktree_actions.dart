import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../store/models.dart';
import '../../store/store.dart';
import '../widgets/sheet_header.dart';

/// Whether [w]'s branch can be renamed. Mirrors the desktop sidebar's guards:
/// the primary checkout is the repo itself, a detached worktree has no branch to
/// rename, and renaming out from under an open PR would orphan the PR's head.
bool canRenameWorktree(Worktree w) =>
    !w.isPrimary && w.branch != null && w.pr?.state.toUpperCase() != 'OPEN';

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
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      final cs = Theme.of(sheetContext).colorScheme;
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(title: worktree.branch ?? 'detached'),
            ListTile(
              enabled: canRenameWorktree(worktree),
              leading: const Icon(PhosphorIconsLight.textAa),
              title: const Text('Rename branch'),
              subtitle: canRenameWorktree(worktree)
                  ? null
                  : Text(_renameBlockedReason(worktree)),
              onTap: () => Navigator.pop(sheetContext, 'rename'),
            ),
            ListTile(
              enabled: canDeleteWorktree(worktree),
              leading: Icon(PhosphorIconsLight.trash, color: cs.error),
              title: Text('Delete worktree', style: TextStyle(color: cs.error)),
              subtitle: canDeleteWorktree(worktree)
                  ? null
                  : const Text('The primary checkout cannot be removed'),
              onTap: () => Navigator.pop(sheetContext, 'delete'),
            ),
          ],
        ),
      );
    },
  );
  if (action == null || !context.mounted) return;
  switch (action) {
    case 'rename':
      await _renameBranch(context, ref, repo: repo, worktree: worktree);
    case 'delete':
      await _deleteWorktree(context, ref, repo: repo, worktree: worktree);
  }
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
  final messenger = ScaffoldMessenger.of(context);
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
    messenger.showSnackBar(SnackBar(content: Text('Rename failed: $e')));
  }
}

Future<void> _deleteWorktree(
  BuildContext context,
  WidgetRef ref, {
  required RepoInfo repo,
  required Worktree worktree,
}) async {
  final messenger = ScaffoldMessenger.of(context);
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
    messenger.showSnackBar(SnackBar(content: Text('Delete failed: $e')));
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
