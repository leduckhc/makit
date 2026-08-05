import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../widgets/pr_sheet.dart';
import '../widgets/pr_state_style.dart';

/// Branch name pill with a git branch glyph.
class BranchChip extends StatelessWidget {
  const BranchChip({super.key, required this.branch, this.subtle = false});
  final String branch;
  final bool subtle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = subtle ? cs.outline : cs.primary;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: kSpace8,
        vertical: kSpace2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(kRadius8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(PhosphorIconsLight.gitCommit, size: kPillIconSize, color: color),
          const SizedBox(width: kSpace4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(
              branch,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelXs?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// `+N −M` diff chip with additive-green / deletive-red counts.
class DiffChip extends StatelessWidget {
  const DiffChip({
    super.key,
    required this.insertions,
    required this.deletions,
  });
  final int insertions;
  final int deletions;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (insertions > 0)
          Text(
            '+$insertions',
            style: Theme.of(context).textTheme.labelXs?.mono.copyWith(
              color: Theme.of(context).colorScheme.diffAddText,
              fontWeight: FontWeight.w400,
            ),
          ),
        if (insertions > 0 && deletions > 0) const SizedBox(width: 5),
        if (deletions > 0)
          Text(
            '−$deletions',
            style: Theme.of(context).textTheme.labelXs?.mono.copyWith(
              color: Theme.of(context).colorScheme.diffDelText,
              fontWeight: FontWeight.w400,
            ),
          ),
      ],
    );
  }
}

/// Worktree PR pill: `PR #42`, tinted by [prPillColors] — an open PR by its CI
/// verdict, a merged/closed one by its state, a draft grey. Same rule as the
/// session chip and the desktop composer pill, so a failing PR cannot read red
/// in one place and brand-blue here. Tapping opens the shared PR sheet
/// ([showPrSheet]) — the same detail the session screen's chip shows, so there is
/// one PR surface with two entry points.
class PrPill extends StatelessWidget {
  const PrPill({super.key, required this.pr});
  final PullRequest pr;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = prStateStyle(cs, pr);
    final (icon: color, label: labelColor) = prPillColors(cs, pr);
    // The tap target is the full row height (kTouchRow) while the *painted*
    // pill stays content-sized: the pill opens the PR sheet, so it needs a
    // thumb-sized target, but inflating the visible chip to 44px would make a
    // blob of it and push the worktree row well past the density the list is
    // tuned for. So the ink/hit box is tall and transparent, and the tint is
    // drawn by the shrink-wrapped box inside it.
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(kRadius8),
        onTap: () => showPrSheet(context, pr),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: kTouchRow),
          child: Center(
            widthFactor: 1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(kRadius8),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: kSpace8,
                  vertical: kSpace2,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    style.glyph.build(size: kPillIconSize, color: color),
                    const SizedBox(width: 3),
                    Text(
                      'PR #${pr.number}',
                      style: Theme.of(context).textTheme.labelXs?.copyWith(
                        color: labelColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Generic little tag chip (default / draft).
class TagChip extends StatelessWidget {
  const TagChip({super.key, required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: kSpace8,
        vertical: kSpace2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(kRadius8),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelXs?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Session status pill (running / you / approve / error / exited / idle).
class SessionStatusChip extends StatelessWidget {
  const SessionStatusChip({super.key, required this.status});
  final SessionStatus status;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (label, color) = switch (status) {
      SessionStatus.running => ('running', cs.primary),
      SessionStatus.awaitingInput => ('you', kStatusWarning),
      SessionStatus.awaitingApproval => ('approve', kStatusCaution),
      SessionStatus.error => ('error', cs.error),
      SessionStatus.exited => ('exited', cs.outline),
      SessionStatus.idle => ('idle', cs.outline),
    };
    // Vivid hue tints the pill; label uses an AA-safe foreground on light.
    final textColor = switch (status) {
      SessionStatus.awaitingInput => cs.statusWarningText,
      SessionStatus.awaitingApproval => cs.statusCautionText,
      _ => color,
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: kSpace8,
        vertical: kSpace2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(kRadius8),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelXs?.copyWith(
          color: textColor,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Agent avatar: shows the agent's logo for known agents, else the initial.
class AgentAvatar extends StatelessWidget {
  const AgentAvatar({super.key, required this.agent, this.size = 32});
  final String agent;
  final double size;

  @override
  Widget build(BuildContext context) {
    final asset = _agentLogos[agent.toLowerCase()];
    if (asset == null) {
      return CircleAvatar(
        radius: size / 2,
        backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
        child: Text(agent.isEmpty ? '?' : agent.substring(0, 1).toUpperCase()),
      );
    }
    return ClipOval(
      child: SvgPicture.asset(
        asset,
        width: size,
        height: size,
        fit: BoxFit.cover,
      ),
    );
  }
}

const _agentLogos = <String, String>{
  'pi': 'assets/agents/pi.svg',
  'codex': 'assets/agents/codex.svg',
  'claude': 'assets/agents/claude.svg',
};

/// Distinct base branches a new session can fork off, for the new-session
/// picker: the repo's default branch first, then its current branch, then any
/// other branches that back a live worktree. De-duplicated, order preserved.
List<String> branchOptionsForRepo(RepoInfo repo) {
  final out = <String>[];
  void add(String? b) {
    if (b != null && b.isNotEmpty && !out.contains(b)) out.add(b);
  }

  add(repo.defaultBranch);
  add(repo.currentBranch);
  for (final w in repo.worktrees) {
    add(w.branch);
  }
  return out;
}

/// Display order shared by mobile home and the desktop sidebar: primary
/// checkout first, then worktrees with live sessions or changes, biggest diff
/// first.
List<Worktree> sortWorktreesForDisplay(Iterable<Worktree> worktrees) {
  final out = [...worktrees];
  out.sort((a, b) {
    if (a.isPrimary != b.isPrimary) return a.isPrimary ? -1 : 1;
    final aActive = a.sessionIds.isNotEmpty || a.hasChanges;
    final bActive = b.sessionIds.isNotEmpty || b.hasChanges;
    if (aActive != bActive) return aActive ? -1 : 1;
    return (b.insertions + b.deletions) - (a.insertions + a.deletions);
  });
  return out;
}

/// Human-readable HEAD-commit age like `3d ago`, shared by the mobile worktree
/// row and the desktop sidebar's sub-row. Empty string when unknown, so a
/// caller that reserves the line keeps its vertical space.
String branchAgeLabel(DateTime? committedAt) {
  if (committedAt == null) return '';
  final d = DateTime.now().difference(committedAt);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 30) return '${d.inDays}d ago';
  if (d.inDays < 365) return '${(d.inDays / 30).floor()}mo ago';
  return '${(d.inDays / 365).floor()}y ago';
}

/// What a worktree's accent bar says about it (SPEC-19, direction C). Ordered
/// by urgency; [worktreeAccent] resolves a worktree's sessions to one of these.
enum WorktreeAccent {
  /// A session is blocked on the user — approve a tool call, answer a question.
  wantsYou,

  /// A session ended badly and nobody has looked at it.
  failed,

  /// An agent is working. Nothing for the user to do yet.
  working,

  /// Nothing running; the branch is just sitting there.
  none,
}

/// Resolve the accent for a worktree from the sessions living in it.
///
/// Precedence is deliberate: a request for the user always wins, because the bar
/// exists to be scanned down a long list and "someone is waiting on me" is the
/// only state with a deadline. A failure outranks progress for the same reason.
/// Drafts are excluded — a pending session has not started, so colouring its
/// branch would promise activity that isn't there.
WorktreeAccent worktreeAccent(List<Session> sessions) {
  var failed = false;
  var working = false;
  for (final s in sessions) {
    if (s.pending) continue;
    switch (s.status) {
      case SessionStatus.awaitingInput:
      case SessionStatus.awaitingApproval:
        return WorktreeAccent.wantsYou; // nothing outranks this
      case SessionStatus.error:
        failed = true;
      case SessionStatus.running:
        working = true;
      case SessionStatus.idle:
      case SessionStatus.exited:
        break;
    }
  }
  if (failed) return WorktreeAccent.failed;
  if (working) return WorktreeAccent.working;
  return WorktreeAccent.none;
}
