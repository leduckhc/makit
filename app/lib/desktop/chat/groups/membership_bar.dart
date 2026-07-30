/// SPEC-30 — the membership bar under the group tabs: a kind chip naming the
/// active group, a one-line explanation of how membership behaves, and the
/// `Split | Tabs` toggle that pins the group's placement mode (decision 9).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../../app/theme.dart';
import '../../../store/store.dart';
import '../panes/workspace_controller.dart';
import 'group.dart';
import 'group_providers.dart';
import 'groups_controller.dart';
import 'placement.dart';

/// The bar beneath the group tabs. Reads the active group and explains — in the
/// group's own voice — what its membership rule is.
/// Below this canvas width the explanatory sentence is dropped so the chip and
/// the toggle keep their space. Chosen as the point where a realistic chip
/// ("Board · Shipping 0.9") plus the toggle leave no useful room for prose.
const double _kSentenceMinWidth = 420;

class MembershipBar extends ConsumerWidget {
  /// Creates the membership bar.
  const MembershipBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final group = ref.watch(activeGroupProvider);
    final members = ref.watch(groupMembersProvider(group.id));
    final isBoard = group.kind == GroupKind.board;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: kSpace12,
        vertical: kSpace8,
      ),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        border: Border(bottom: BorderSide(color: cs.outlineVariant)),
      ),
      // The canvas can be squeezed to ~350px (sidebar dragged to its widest),
      // where the chip and the toggle alone exceed the width — an `Expanded`
      // sentence between them cannot save that, because neither neighbour
      // shrinks. So the bar degrades deliberately: the sentence is dropped
      // first (it explains, it does not act), and the chip is flexible so even
      // an extreme squeeze ellipsizes rather than overflowing.
      child: LayoutBuilder(
        builder: (context, constraints) {
          final roomForSentence = constraints.maxWidth >= _kSentenceMinWidth;
          return Row(
            children: [
              Flexible(
                child: _KindChip(
                  icon: isBoard
                      ? PhosphorIconsLight.robot
                      : PhosphorIconsLight.gitBranch,
                  label: isBoard
                      ? 'Board · ${group.label}'
                      : '${_repoName(ref, group)} · ${group.label}',
                  color: isBoard ? kBoardSwatch : cs.primary,
                ),
              ),
              if (roomForSentence) ...[
                const SizedBox(width: kSpace10),
                Expanded(
                  child: Text(
                    _sentence(ref, group, members),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ] else
                const Spacer(),
              const SizedBox(width: kSpace10),
              _LayoutToggle(group: group),
            ],
          );
        },
      ),
    );
  }

  /// The active group's repo name for the chip, falling back to the raw
  /// project id when the repo list has not arrived yet.
  String _repoName(WidgetRef ref, Group group) {
    final projectId = group.projectId;
    if (projectId == null) return '';
    // watch, not read: the repo list can arrive after first paint, and a read
    // would leave the chip stuck on the raw project id forever.
    return ref.watch(reposProvider).byId(projectId)?.name ?? projectId;
  }

  /// The explanatory sentence, phrased per kind (matching the mock exactly).
  String _sentence(WidgetRef ref, Group group, List<String> members) {
    final count = members.length;
    if (group.kind == GroupKind.worktree) {
      return '$count agent${count == 1 ? '' : 's'} on this branch — a new '
          'session here joins automatically, and nothing else can appear';
    }
    final sessions = ref.watch(sessionsProvider);
    final repos = <String>{
      for (final id in members) ?sessions.byId(id)?.projectId,
    };
    return '$count pinned agent${count == 1 ? '' : 's'} across '
        '${repos.length} repo(s) — nothing joins unless you add it';
  }
}

/// The kind chip: a tinted, bordered pill with a leading glyph and the group's
/// identity — green (derived) or violet (curated).
class _KindChip extends StatelessWidget {
  const _KindChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: kSpace8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        border: Border.all(color: color.withValues(alpha: 0.28)),
        borderRadius: BorderRadius.circular(kRadius8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: kPillIconSize, color: color),
          const SizedBox(width: kSpace6),
          // Flexible is the load-bearing part: without it the chip's intrinsic
          // width wins and the toggle is pushed off the bar (verified — removing
          // it overflows by 185px at 340 wide; removing the Flexible *around*
          // the chip overflows by 105px, so both are needed). The ellipsis is
          // cosmetic: it stops the label being clipped mid-glyph.
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: theme.textTheme.labelSmall?.copyWith(
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

/// The `Split | Tabs` segmented toggle. Clicking a segment pins the group's
/// layout override **and** re-lays-out the active group's tree once, on that
/// click (decision 9): `split` gives every shown member its own pane, `tabs`
/// collapses them into one pane's tab strip. The highlighted segment is the
/// group's *explicit* override, so with none set neither is lit — placement
/// then follows the threshold silently, exactly as the mock behaves.
///
/// This is the **one** place a tree is rearranged on purpose; every other path
/// only ever *places* a newcomer beside untouched panes (decision 9's point).
class _LayoutToggle extends ConsumerWidget {
  const _LayoutToggle({required this.group});

  final Group group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;

    // Pin the override, then rearrange the live canvas through its controller so
    // the mutation flows back to the groups layer via the commit sink. Order is
    // immaterial — setLayoutOverride does not rebuild the workspace controller
    // (it keys on the active group's identity, not its tree) — but pinning
    // first mirrors the mock's "set the override, then lay out once".
    void apply(LayoutMode mode) {
      ref
          .read(groupsControllerProvider.notifier)
          .setLayoutOverride(group.id, mode);
      relayoutInto(ref.read(workspaceControllerProvider.notifier), mode);
    }

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(kRadius8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // A tap on the already-pinned segment is a no-op: `apply` unbinds every
          // shown session and re-places it, so re-applying the current mode would
          // rewrite the whole tree (and persist it) for no visible change.
          _ToggleSegment(
            label: 'Split',
            selected: group.layoutOverride == LayoutMode.split,
            onTap: group.layoutOverride == LayoutMode.split
                ? null
                : () => apply(LayoutMode.split),
          ),
          _ToggleSegment(
            label: 'Tabs',
            selected: group.layoutOverride == LayoutMode.tabs,
            onTap: group.layoutOverride == LayoutMode.tabs
                ? null
                : () => apply(LayoutMode.tabs),
          ),
        ],
      ),
    );
  }
}

class _ToggleSegment extends StatelessWidget {
  const _ToggleSegment({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;

  /// Null when this segment is already the pinned mode, so tapping it does
  /// nothing rather than rewriting the tree for no change.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: kSpace10, vertical: 3),
        color: selected ? cs.surfaceContainerHighest : Colors.transparent,
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: selected ? cs.onSurface : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
