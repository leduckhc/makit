import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';

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

/// Open-PR pill: `PR #42`, tinted grey for drafts, brand for ready.
class PrPill extends StatelessWidget {
  const PrPill({super.key, required this.pr});
  final PullRequest pr;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = pr.isDraft ? cs.outline : cs.primary;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: kSpace8,
        vertical: kSpace2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(kRadius8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            PhosphorIconsLight.gitPullRequest,
            size: kPillIconSize,
            color: color,
          ),
          const SizedBox(width: 3),
          Text(
            'PR #${pr.number}',
            style: Theme.of(context).textTheme.labelXs?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
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
