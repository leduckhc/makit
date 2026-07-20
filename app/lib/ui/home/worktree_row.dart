import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../store/models.dart';
import '../../app/theme.dart' show kMakitAccent;
import 'repo_chips.dart';
import 'session_tile.dart';

/// Brand green accent used for running/active glass affordances (shared token).
const _kBrandBlue = kMakitAccent;

/// One worktree (branch) row inside a repo card, listing the sessions running
/// in it (SPEC-19, moved from home_screen). Renders nothing when it has no
/// live session.
class WorktreeRow extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final branch = worktree.branch ?? 'detached';
    final isDefault = worktree.branch == repo.defaultBranch;
    final isCurrent =
        worktree.branch != null && worktree.branch == repo.currentBranch;

    // Only surface worktrees with a live session (strict).
    if (sessions.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Row(
            children: [
              Icon(
                PhosphorIconsLight.treeStructure,
                size: 15,
                color: worktree.isPrimary
                    ? theme.colorScheme.outline
                    : _kBrandBlue,
              ),
              const SizedBox(width: 6),
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
                const Icon(PhosphorIconsFill.star, size: 15, color: Colors.amber),
              ],
              if (isDefault) ...[
                const SizedBox(width: 6),
                TagChip(label: 'default', color: theme.colorScheme.outline),
              ],
              const SizedBox(width: 8),
              if (worktree.hasChanges)
                DiffChip(
                  insertions: worktree.insertions,
                  deletions: worktree.deletions,
                ),
              if (worktree.pr != null) ...[
                const SizedBox(width: 8),
                PrPill(pr: worktree.pr!),
              ],
            ],
          ),
        ),
        ...sessions.map((s) => SessionTile(session: s, indented: true)),
      ],
    );
  }
}
