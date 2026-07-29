/// SPEC-30 — the membership bar under the group tabs: a kind chip naming the
/// active group, a one-line explanation of how membership behaves, and the
/// `Split | Tabs` toggle that pins the group's placement mode (decision 9).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../../app/theme.dart';
import '../../../store/store.dart';
import 'group.dart';
import 'group_bar.dart' show kBoardSwatchColor;
import 'group_providers.dart';
import 'groups_controller.dart';

/// The bar beneath the group tabs. Reads the active group and explains — in the
/// group's own voice — what its membership rule is.
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
      child: Row(
        children: [
          _KindChip(
            icon: isBoard
                ? PhosphorIconsLight.robot
                : PhosphorIconsLight.gitBranch,
            label: isBoard
                ? 'Board · ${group.label}'
                : '${_repoName(ref, group)} · ${group.label}',
            color: isBoard ? kBoardSwatchColor : cs.primary,
          ),
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
          const SizedBox(width: kSpace10),
          _LayoutToggle(group: group),
        ],
      ),
    );
  }

  /// The active group's repo name for the chip, falling back to the raw
  /// project id when the repo list has not arrived yet.
  String _repoName(WidgetRef ref, Group group) {
    final projectId = group.projectId;
    if (projectId == null) return '';
    return ref.read(reposProvider).byId(projectId)?.name ?? projectId;
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
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// The `Split | Tabs` segmented toggle. Clicking a segment pins the group's
/// layout override (decision 9); the highlighted segment is the group's
/// *explicit* override, so with none set neither is lit — the placement then
/// follows the threshold silently, exactly as the mock behaves.
///
/// Re-laying-out the tree on that click is Lane 3's job; this only records the
/// override.
class _LayoutToggle extends ConsumerWidget {
  const _LayoutToggle({required this.group});

  final Group group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final controller = ref.read(groupsControllerProvider.notifier);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(kRadius8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ToggleSegment(
            label: 'Split',
            selected: group.layoutOverride == LayoutMode.split,
            onTap: () => controller.setLayoutOverride(group.id, LayoutMode.split),
          ),
          _ToggleSegment(
            label: 'Tabs',
            selected: group.layoutOverride == LayoutMode.tabs,
            onTap: () => controller.setLayoutOverride(group.id, LayoutMode.tabs),
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
  final VoidCallback onTap;

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
