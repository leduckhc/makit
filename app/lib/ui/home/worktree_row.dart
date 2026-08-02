import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import 'repo_chips.dart';
import 'session_tile.dart';
import 'worktree_actions.dart';

/// Width reserved for the disclosure caret, so a worktree without one still
/// lines its branch name up with the rows that have one.
const double _kCaretSlot = 18;

/// One worktree (branch) row inside a repo card, listing the sessions running
/// in it (SPEC-19, moved from home_screen). Every worktree is listed — one with
/// no session still shows its branch, diff and PR, matching the desktop sidebar
/// (SPEC-11), because a branch carrying work is the thing you most want to
/// start a session *on*.
///
/// The sessions fold away, as in the sidebar. Unlike the sidebar the whole row
/// toggles as well as the caret: desktop splits the two because its row also
/// navigates (SPEC-30 decision 15), and a phone has no worktree canvas to
/// navigate to — so the gesture is free, and a thumb-sized target is worth more
/// than an 18px one.
class WorktreeRow extends ConsumerStatefulWidget {
  const WorktreeRow({
    super.key,
    required this.repo,
    required this.worktree,
    required this.sessions,
  });
  final RepoInfo repo;
  final Worktree worktree;
  final List<Session> sessions;

  @override
  ConsumerState<WorktreeRow> createState() => _WorktreeRowState();
}

class _WorktreeRowState extends ConsumerState<WorktreeRow> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repo = widget.repo;
    final worktree = widget.worktree;
    final sessions = widget.sessions;
    final branch = worktree.branch ?? 'detached';
    final isDefault = worktree.branch == repo.defaultBranch;
    final isCurrent =
        worktree.branch != null && worktree.branch == repo.currentBranch;
    final canFold = sessions.isNotEmpty;
    // How long ago this branch last moved. Empty when git gave no commit date,
    // in which case the line is dropped rather than reserved — vertical space is
    // scarcer on a phone than in the sidebar, which keeps it for alignment.
    final age = branchAgeLabel(worktree.committedAt);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: canFold ? () => setState(() => _expanded = !_expanded) : null,
          // Long-press for the worktree's own actions (rename / delete): tap is
          // taken by the fold, and desktop's hover reveal has no touch analogue.
          onLongPress: () =>
              showWorktreeActions(context, ref, repo: repo, worktree: worktree),
          child: ConstrainedBox(
            // Dense like the sidebar's row, but never below the touch floor:
            // desktop's 24px row assumes a pointer.
            constraints: const BoxConstraints(minHeight: kTouchRow),
            child: Padding(
              // No vertical padding: the row's floor is kTouchRow, and its
              // tallest child (the PR pill's 44px tap box) fills it exactly.
              // Padding on top of that would stack, fattening the row.
              padding: const EdgeInsets.fromLTRB(12, 0, 16, 0),
              child: Row(
                children: [
                  // Only a row with something to fold gets a caret; the slot is
                  // kept either way so branch names stay aligned.
                  if (canFold)
                    _Caret(
                      key: Key('worktreeCaret-${worktree.path}'),
                      expanded: _expanded,
                      onPressed: () => setState(() => _expanded = !_expanded),
                    )
                  else
                    const SizedBox(width: _kCaretSlot),
                  Icon(
                    PhosphorIconsLight.treeStructure,
                    size: 15,
                    color: worktree.isPrimary
                        ? theme.colorScheme.outline
                        : theme.colorScheme.primary,
                  ),
                  const SizedBox(width: kSpace6),
                  Flexible(
                    child: Text(
                      branch,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontFeatures: const [],
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (isCurrent) ...[
                    const SizedBox(width: 5),
                    Icon(
                      PhosphorIconsFill.star,
                      size: 15,
                      color: theme.colorScheme.primary,
                    ),
                  ],
                  if (isDefault) ...[
                    const SizedBox(width: kSpace6),
                    TagChip(label: 'default', color: theme.colorScheme.outline),
                  ],
                  const SizedBox(width: kSpace8),
                  if (worktree.hasChanges)
                    DiffChip(
                      insertions: worktree.insertions,
                      deletions: worktree.deletions,
                    ),
                  if (worktree.pr != null) ...[
                    const SizedBox(width: kSpace8),
                    PrPill(pr: worktree.pr!),
                  ],
                ],
              ),
            ),
          ),
        ),
        if (age.isNotEmpty)
          Padding(
            // Indented past the caret slot and the branch glyph so it hangs
            // under the branch name, as the sidebar's sub-row does.
            padding: const EdgeInsets.fromLTRB(
              12 + _kCaretSlot + 15 + kSpace6,
              0,
              16,
              6,
            ),
            child: Text(
              age,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
                fontWeight: FontWeight.w300,
              ),
            ),
          ),
        if (_expanded)
          ...sessions.map((s) => SessionTile(session: s, indented: true)),
      ],
    );
  }
}

/// The row's disclosure caret. Its own tap target as well as the row's, so the
/// affordance the chevron advertises actually works when aimed at directly.
class _Caret extends StatelessWidget {
  const _Caret({super.key, required this.expanded, required this.onPressed});

  final bool expanded;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _kCaretSlot,
      height: _kCaretSlot,
      child: InkWell(
        borderRadius: BorderRadius.circular(kRadius6),
        onTap: onPressed,
        child: Center(
          child: AnimatedRotation(
            turns: expanded ? 0 : -0.25,
            duration: const Duration(milliseconds: 120),
            child: Icon(
              PhosphorIconsLight.caretDown,
              size: 12,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ),
      ),
    );
  }
}
