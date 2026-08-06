import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../widgets/pr_detail.dart';
import '../widgets/pr_signals.dart';
import '../widgets/pr_tone.dart';
import '../widgets/wrap_up.dart';

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

/// The worktree's status, as a sentence fragment: a tone dot plus the loudest
/// fact — `● 2 checks failing`. Tapping opens the shared detail sheet.
///
/// Replaces the old `PR #42` pill, whose colour was the only signal it carried:
/// you could see that *something* was wrong but not what, and a merged PR looked
/// identical to a live one apart from a hue. This says it, and a merged row
/// advertises its own clean-up ("merged") so the ending is one tap away instead
/// of hidden behind a long-press.
///
/// Widest the chip's label may get before it elides.
///
/// The row also carries the branch name and a trailing age, and the chip sits
/// between them: much past this and `#142 · 2 checks failing` starts pushing the
/// age off a narrow phone. Elide instead — the sheet has the full sentence.
const double _kChipLabelMaxWidth = 190;

/// Reads the shared [PrStatus] derivation, so the home row, the session chip and
/// the desktop bar cannot disagree about whether a PR is failing.
class PrStatusChip extends ConsumerWidget {
  const PrStatusChip({
    super.key,
    required this.status,
    required this.repo,
    required this.worktree,
    this.onInsertPrompt,
  });

  /// The derived facts. Passed in rather than derived here so the caller can
  /// decide whether the row is worth a chip at all ([PrStatus.isQuiet]).
  final PrStatus status;

  final RepoInfo repo;
  final Worktree worktree;

  /// Where a canned prompt goes when picked from the sheet. Null on a surface
  /// with no composer (the home list), which hides the prompt remedies but keeps
  /// the direct ones — wrapping up needs no composer.
  final void Function(String prompt)? onInsertPrompt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    // The chip's label; its background keeps the vivid dot hue below.
    final tone = prToneTextColor(cs, status.tone);

    // The tap target is the full row height (kTouchRow) while the painted chip
    // stays content-sized: it opens a sheet, so it needs a thumb-sized target,
    // but inflating the visible chip to 44px would make a blob of it and push
    // the row past the density the list is tuned for.
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(kRadius8),
        onTap: () => showPrDetail(
          context,
          status: status,
          pr: worktree.pr,
          sheet: true,
          canInsertPrompt: onInsertPrompt != null,
          onRun: (remedy) => runPrRemedy(
            context,
            ref,
            remedy: remedy,
            status: status,
            pr: worktree.pr,
            projectId: repo.id,
            worktreePath: worktree.path,
            branch: worktree.branch,
            uncommittedFiles: worktree.uncommittedFiles,
            onInsertPrompt: onInsertPrompt ?? (_) {},
          ),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: kTouchRow),
          child: Center(
            widthFactor: 1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: prToneColor(cs, status.tone).withValues(alpha: 0.14),
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
                    PrToneDot(
                      tone: status.tone,
                      progress: status.checkProgress,
                      hollow: worktree.pr == null,
                    ),
                    const SizedBox(width: kSpace6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: _kChipLabelMaxWidth,
                      ),
                      child: Text(
                        status.hasPr
                            ? '${status.identity} · ${status.loud.label}'
                            : status.loud.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelXs?.copyWith(
                          color: tone,
                          fontWeight: FontWeight.w600,
                        ),
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
