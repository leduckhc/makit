import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import 'repo_chips.dart';
import 'session_tile.dart';
import 'start_session.dart';
import 'worktree_actions.dart';

/// Width of the accent bar down a worktree's leading edge.
const double _kAccentBar = 3;

/// Indent that lines a worktree's sub-content (meta chips, sessions) up under
/// its branch name — past the branch glyph and its gap.
const double _kSubIndent = 21;

/// One worktree (branch) inside a repo card, listing the sessions running in it
/// (SPEC-19).
///
/// The leading accent bar encodes state ([worktreeAccent]) so a long list can be
/// scanned by colour alone: orange means a session is blocked on you, red that
/// one failed, green that an agent is working. Every worktree is listed — one
/// with no session still shows its branch, diff and PR, matching the desktop
/// sidebar (SPEC-11), because a branch carrying work is the thing you most want
/// to start a session *on*.
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
    final cs = theme.colorScheme;
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
    final accent = worktreeAccent(sessions);
    final hasMeta =
        isDefault || worktree.hasChanges || worktree.pr != null || age.isNotEmpty;

    return Container(
      // The accent is a left border rather than a stretched child: it needs no
      // IntrinsicHeight to match the block's height, and `Container` insets the
      // content by the border itself. A transparent accent still reserves its
      // 3px, so branch names stay aligned whatever the state.
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: cs.outlineVariant),
          left: BorderSide(
            color: accentColor(cs, accent),
            width: _kAccentBar,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: canFold
                ? () => setState(() => _expanded = !_expanded)
                : null,
            // Long-press for the worktree's own actions (rename / delete):
            // tap is taken by the fold, and desktop's hover reveal has no
            // touch analogue.
            onLongPress: () => showWorktreeActions(
              context,
              ref,
              repo: repo,
              worktree: worktree,
            ),
            child: ConstrainedBox(
              // Dense like the sidebar's row, but never below the touch floor:
              // desktop's 24px row assumes a pointer. Applies to the tappable
              // line only — the meta line below is not a target.
              constraints: const BoxConstraints(minHeight: kTouchRow),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  kSpace10,
                  kSpace8,
                  kSpace4,
                  hasMeta ? 0 : kSpace8,
                ),
                child: Row(
                  children: [
                    Icon(
                      // The branch glyph, as in the desktop sidebar and the
                      // window title strip (DESIGN.md → "no PR → branch
                      // symbol"). A worktree is a checked-out branch, so it
                      // reads as one everywhere.
                      PhosphorIconsLight.gitBranch,
                      size: 15,
                      color: worktree.isPrimary ? cs.outline : cs.primary,
                    ),
                    const SizedBox(width: kSpace6),
                    // Takes whatever the fixed trailing controls leave, and
                    // ellipsizes. Chips live on the meta line below, because on
                    // a 320pt phone a dirty branch with an open PR could not fit
                    // beside them.
                    Expanded(
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
                        size: 13,
                        color: cs.primary,
                      ),
                    ],
                    if (canFold)
                      _Caret(
                        key: Key('worktreeCaret-${worktree.path}'),
                        expanded: _expanded,
                        onPressed: () =>
                            setState(() => _expanded = !_expanded),
                      ),
                    // Start a session on *this* branch. Without it the only way
                    // in was the card-level "New session", which reopens the
                    // worktree picker — asking again for the branch the user is
                    // already pointing at.
                    _NewSessionButton(
                      key: Key('newSessionInWorktree-${worktree.path}'),
                      onPressed: () => startSessionFlow(
                        context,
                        ref,
                        repo,
                        worktree: worktree,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Meta line: the branch's state, wrapping instead of overflowing.
          if (hasMeta)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                kSpace10 + _kSubIndent,
                kSpace4,
                kSpace8,
                kSpace8,
              ),
              child: Wrap(
                spacing: kSpace8,
                runSpacing: kSpace4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (isDefault) TagChip(label: 'default', color: cs.outline),
                  if (worktree.hasChanges)
                    DiffChip(
                      insertions: worktree.insertions,
                      deletions: worktree.deletions,
                    ),
                  if (worktree.pr != null) PrPill(pr: worktree.pr!),
                  if (age.isNotEmpty)
                    Text(
                      age,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.outline,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                ],
              ),
            ),
          if (_expanded)
            ...sessions.map(
              (s) => Padding(
                padding: const EdgeInsets.fromLTRB(
                  kSpace10 + _kSubIndent,
                  0,
                  kSpace8,
                  kSpace8,
                ),
                child: SessionTile(session: s),
              ),
            ),
        ],
      ),
    );
  }
}

/// The accent bar's colour. `none` is transparent rather than a grey line, so a
/// quiet branch adds no visual weight and the coloured ones stand out.
Color accentColor(ColorScheme cs, WorktreeAccent accent) => switch (accent) {
  WorktreeAccent.wantsYou => kStatusCaution,
  WorktreeAccent.failed => cs.error,
  WorktreeAccent.working => cs.primary,
  WorktreeAccent.none => Colors.transparent,
};

/// The row's disclosure caret. Its own tap target, so the affordance the chevron
/// advertises actually works when aimed at directly.
class _Caret extends StatelessWidget {
  const _Caret({super.key, required this.expanded, required this.onPressed});

  final bool expanded;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 26,
      height: 26,
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

/// The worktree row's "start a session here" button.
///
/// A quiet `+` rather than a filled button: every row carries one, so at list
/// density a loud control would read as the row's subject instead of its action.
class _NewSessionButton extends StatelessWidget {
  const _NewSessionButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'New session on this branch',
      child: InkWell(
        borderRadius: BorderRadius.circular(kRadius8),
        onTap: onPressed,
        child: SizedBox(
          width: 30,
          height: 30,
          child: Center(
            child: Icon(PhosphorIconsLight.plus, size: 16, color: cs.outline),
          ),
        ),
      ),
    );
  }
}
