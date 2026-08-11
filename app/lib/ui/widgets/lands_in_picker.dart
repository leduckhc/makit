/// The "Lands in" picker: choose the branch a worktree's work lands in.
///
/// One list, two shells — a bottom sheet on touch, a `MenuAnchor` on desktop —
/// mirroring how the model picker is already built, so this introduces no new
/// pattern. The ranking and the diff previews come from the server
/// (`worktree.targetCandidates`); this file only renders them.
///
/// Reached from three places, all of which are *disclosures* rather than
/// first-glance UI: the worktree-actions menu (the canonical home, since the
/// target is a property of a worktree and that is the only per-worktree menu),
/// the composer's `Ship it` caret menu, and the PR detail sheet's header.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../../store/store.dart';
import 'sheet_header.dart';

/// The glyph that reads "lands in": a doubled caret, i.e. *append into*.
///
/// A single arrow is the app's generic "goes to"; the doubled form distinguishes
/// a merge destination from mere navigation.
const IconData kLandsInIcon = PhosphorIconsLight.caretDoubleRight;

/// `branch ≫ target` — the one line that says where work lands.
///
/// Asymmetric on purpose: the source is muted, the target carries the emphasis
/// and (when [onTap] is given) the affordance. Rendered at equal weight the pair
/// reads as two unrelated facts, when the whole point is that the right half is a
/// control.
class LandsInLine extends StatelessWidget {
  const LandsInLine({
    super.key,
    this.sourceBranch,
    required this.targetBranch,
    this.targetResolved = true,
    this.onTap,
    this.trailing,
  });

  /// The head branch. Omitted where the surface's title already is the branch —
  /// printing it twice wastes the line.
  final String? sourceBranch;

  /// Where it lands. Null renders a placeholder rather than an empty gap.
  final String? targetBranch;

  /// False when the target could not be resolved (deleted, unfetched): the line
  /// switches to a warning tone, because a target that cannot be resolved is the
  /// reason the diff numbers went missing.
  final bool targetResolved;

  final VoidCallback? onTap;

  /// Optional tail, e.g. the diff numbers.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final unresolved = targetBranch != null && !targetResolved;
    final targetColor = unresolved ? cs.statusWarningText : cs.onSurface;
    final mono = theme.textTheme.labelSmall?.mono;

    final target = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (unresolved) ...[
          Icon(
            PhosphorIconsLight.warning,
            size: 12,
            color: cs.statusWarningText,
          ),
          const SizedBox(width: kSpace4),
        ],
        Flexible(
          child: Text(
            targetBranch ?? 'not set',
            style: mono?.copyWith(
              color: targetColor,
              fontWeight: FontWeight.w600,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (onTap != null) ...[
          const SizedBox(width: kSpace2),
          Icon(PhosphorIconsLight.caretDown, size: 11, color: cs.outline),
        ],
      ],
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (sourceBranch != null) ...[
          Flexible(
            child: Text(
              sourceBranch!,
              style: mono?.copyWith(color: cs.outline),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: kSpace6),
        ],
        Icon(kLandsInIcon, size: 14, color: cs.outline),
        const SizedBox(width: kSpace6),
        if (onTap == null)
          target
        else
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(kRadius6),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: kSpace4,
                vertical: kSpace2,
              ),
              child: target,
            ),
          ),
        if (trailing != null) ...[
          const SizedBox(width: kSpace6),
          Text('·', style: TextStyle(color: cs.outline)),
          const SizedBox(width: kSpace6),
          trailing!,
        ],
      ],
    );
  }
}

/// `+N −M` for a candidate preview, in the diff hues.
class _Preview extends StatelessWidget {
  const _Preview({required this.insertions, required this.deletions});
  final int insertions;
  final int deletions;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelXs?.mono;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('+$insertions', style: style?.copyWith(color: cs.diffAddText)),
        const SizedBox(width: kSpace4),
        Text('\u2212$deletions', style: style?.copyWith(color: cs.diffDelText)),
      ],
    );
  }
}

/// Open the picker and apply the choice. Returns the chosen branch, or null when
/// dismissed or when the change failed.
///
/// `sheet: true` uses a bottom sheet (touch); false uses a dialog, which is what
/// desktop surfaces that are not menus (the detail sheet header) want.
Future<String?> showLandsInPicker(
  BuildContext context,
  WidgetRef ref, {
  required String projectId,
  required Worktree worktree,
  bool sheet = false,
}) async {
  final store = ref.read(storeControllerProvider.notifier);
  final body = _LandsInPickerBody(
    projectId: projectId,
    worktree: worktree,
    candidatesFuture: store.targetCandidates(projectId, worktree.path),
  );
  final chosen = sheet
      ? await showModalBottomSheet<String>(
          context: context,
          showDragHandle: true,
          isScrollControlled: true,
          builder: (_) => SafeArea(child: body),
        )
      : await showDialog<String>(
          context: context,
          builder: (_) => Dialog(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420, maxHeight: 520),
              child: body,
            ),
          ),
        );
  if (chosen == null || chosen == worktree.targetBranch) return null;
  if (!context.mounted) return null;
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await store.setWorktreeTarget(projectId, worktree.path, chosen);
    return chosen;
  } catch (e) {
    // Never leave the UI showing a value the server refused: the snapshot is the
    // only source of truth, so there is nothing to roll back — just say why.
    messenger?.showSnackBar(
      SnackBar(content: Text('Could not change where this lands: $e')),
    );
    return null;
  }
}

class _LandsInPickerBody extends StatelessWidget {
  const _LandsInPickerBody({
    required this.projectId,
    required this.worktree,
    required this.candidatesFuture,
  });

  final String projectId;
  final Worktree worktree;
  final Future<List<TargetCandidate>> candidatesFuture;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHeader(title: 'Lands in'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, kSpace8),
          child: LandsInLine(
            sourceBranch: worktree.branch,
            targetBranch: worktree.targetBranch,
            targetResolved: worktree.targetResolved,
          ),
        ),
        Flexible(
          child: FutureBuilder<List<TargetCandidate>>(
            future: candidatesFuture,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snap.hasError) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('Could not list branches: ${snap.error}'),
                );
              }
              final all = snap.data ?? const <TargetCandidate>[];
              if (all.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No branches to land in.'),
                );
              }
              return _CandidateList(all: all, current: worktree.targetBranch);
            },
          ),
        ),
      ],
    );
  }
}

/// The grouped list. Section headers appear as the group changes, so the server's
/// ranking drives the layout and the client never re-sorts.
class _CandidateList extends StatelessWidget {
  const _CandidateList({required this.all, required this.current});

  final List<TargetCandidate> all;
  final String? current;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final rows = <Widget>[];
    TargetCandidateGroup? seen;
    for (final c in all) {
      if (c.group != seen) {
        seen = c.group;
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, kSpace12, 16, kSpace4),
            child: Text(
              c.group.label.toUpperCase(),
              style: Theme.of(context).textTheme.labelXs?.copyWith(
                color: cs.outline,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
              ),
            ),
          ),
        );
      }
      rows.add(_CandidateRow(candidate: c, isCurrent: c.branch == current));
    }
    return ListView(shrinkWrap: true, children: rows);
  }
}

class _CandidateRow extends StatelessWidget {
  const _CandidateRow({required this.candidate, required this.isCurrent});

  final TargetCandidate candidate;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = candidate;
    final reason = c.blockedReason;
    return ListTile(
      key: Key('landsInCandidate-${c.branch}'),
      enabled: c.selectable,
      // 44pt floor: this is a thumb target on touch.
      minVerticalPadding: kSpace8,
      leading: Icon(
        c.group == TargetCandidateGroup.forkedFrom
            ? PhosphorIconsLight.gitFork
            : PhosphorIconsLight.gitBranch,
        size: 17,
        color: c.group == TargetCandidateGroup.forkedFrom
            ? cs.primary
            : cs.outline,
      ),
      title: Text(
        c.branch,
        style: Theme.of(context).textTheme.bodyMedium?.mono,
        overflow: TextOverflow.ellipsis,
      ),
      // Explain the block rather than hiding the row — the same convention the
      // worktree and PR action menus use for a disabled entry.
      subtitle: reason == null ? null : Text(reason),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (c.hasPreview)
            _Preview(insertions: c.insertions!, deletions: c.deletions!),
          if (isCurrent) ...[
            const SizedBox(width: kSpace8),
            Icon(PhosphorIconsLight.check, size: 16, color: cs.primary),
          ],
        ],
      ),
      onTap: c.selectable ? () => Navigator.pop(context, c.branch) : null,
    );
  }
}
