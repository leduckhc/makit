/// SPEC-30 — the group tab strip: a horizontally scrolling rail of group tabs
/// (swatch · label · live dot · count · ✕) plus a trailing `+` menu for a new
/// board or reopening a recently-closed one.
///
/// Decision 12: the rail **scrolls horizontally and never wraps**. This widget
/// is *only* the rail — Lane 8 places it beside the pinned IDE launcher, giving
/// it its width through an [Expanded]. It therefore fills the space it is given
/// and lets its tabs scroll under a clip rather than claiming the whole strip.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../../app/theme.dart';
import '../../../shortcuts/keymap_controller.dart';
import '../../../shortcuts/shortcut_action.dart';
import '../../../store/models.dart';
import '../../../store/store.dart';
import '../../../ui/widgets/menu_item.dart';
import '../sidebar_layout.dart' show kTitleBarStripHeight;
import 'group.dart';
import 'group_providers.dart';
import 'groups_controller.dart';

/// Height of the group-bar rail. It stands in for the hidden OS titlebar, so it
/// uses the same perfectly-calibrated macOS titlebar height as [TitleBarStrip]
/// ([kTitleBarStripHeight]) — the outer tabs then fill it and hug the window's
/// top edge, clearing the traffic lights.
const double _kRailHeight = kTitleBarStripHeight;

/// The horizontally scrolling rail of group tabs, ending in the `+` menu.
class GroupBar extends ConsumerWidget {
  /// Creates the group bar.
  const GroupBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Deliberately narrow. `commitTree` rewrites GroupsState on EVERY tree
    // mutation (splitter drag, tab move, ratio change), so watching the whole
    // state would rebuild the entire strip while you drag a divider. The bar
    // renders only identity — ids, kinds, labels, order — so it depends on
    // exactly that, encoded as a string because a List's `==` is identity and
    // would defeat the selector.
    ref.watch(
      groupsControllerProvider.select<String>(
        (s) => s.groups
            .map((g) => '${g.id}\u0000${g.kind.name}\u0000${g.label}')
            .join('\u0001'),
      ),
    );
    final groups = ref.read(groupsControllerProvider).groups;
    final activeId = ref.watch(
      groupsControllerProvider.select<String>((s) => s.active.id),
    );

    // A single horizontally-scrolling Row (never a Wrap) is the whole of
    // decision 12: tabs overflow into a scroll offset instead of a second row.
    return SizedBox(
      height: _kRailHeight,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < groups.length; i++)
              _GroupTab(
                key: ValueKey(groups[i].id),
                group: groups[i],
                index: i,
                active: groups[i].id == activeId,
              ),
            const _NewGroupButton(),
          ],
        ),
      ),
    );
  }
}

/// One group tab: kind swatch, label, a live dot when a member is running, the
/// member count, and a kind-specific ✕.
class _GroupTab extends ConsumerWidget {
  const _GroupTab({
    super.key,
    required this.group,
    required this.index,
    required this.active,
  });

  final Group group;

  /// Position in the rail — decides which `⌘N` shortcut the tooltip names.
  final int index;

  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final isBoard = group.kind == GroupKind.board;
    final members = ref.watch(groupMembersProvider(group.id));
    // Only the running-ness of this tab's members matters here; watching the
    // whole session list rebuilt every tab on any session field change.
    final anyRunning = ref.watch(
      sessionsProvider.select<bool>(
        (s) => members.any((id) => s.byId(id)?.status == SessionStatus.running),
      ),
    );
    final controller = ref.read(groupsControllerProvider.notifier);

    return Tooltip(
      message: _tabTooltip(ref),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => controller.activate(group.id),
          borderRadius: BorderRadius.zero,
          child: Container(
            padding: const EdgeInsets.fromLTRB(kSpace12, 0, kSpace6, 0),
            decoration: BoxDecoration(
              color: active ? cs.surfaceContainer : Colors.transparent,
              border: Border(
                top: BorderSide(
                  color: active ? cs.primary : cs.outlineVariant,
                  width: 2,
                ),
                right: BorderSide(color: cs.outlineVariant, width: 1),
              ),
              borderRadius: BorderRadius.zero,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Kind swatch: green = worktree (derived), violet = board.
                Container(
                  key: const Key('groupKindSwatch'),
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: isBoard ? kBoardSwatch : cs.primary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: kSpace8),
                Flexible(
                  child: Text(
                    group.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: active ? cs.onSurface : cs.onSurfaceVariant,
                    ),
                  ),
                ),
                if (anyRunning) ...[
                  const SizedBox(width: kSpace6),
                  _GroupLiveDot(
                    key: Key('groupLiveDot-${group.id}'),
                    color: cs.primary,
                  ),
                ],
                const SizedBox(width: kSpace6),
                _CountPill(count: members.length, active: active),
                _CloseButton(
                  tooltip: isBoard
                      ? 'Close this board — the list goes to Recently closed'
                      : 'Close this view — the branch, its folder and its '
                            'agents are untouched',
                  onPressed: () => controller.closeGroup(group.id),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The tab's tooltip: what the group is, plus its shortcut. The first nine
  /// name `⌘N` (the live keymap chord); the tenth onward say so explicitly
  /// (decision 16).
  String _tabTooltip(WidgetRef ref) {
    final base = group.kind == GroupKind.worktree
        ? 'Worktree group — membership follows the branch'
        : 'Board — hand-picked, can span repos';
    final action = ShortcutAction.switchGroupAtIndex(index);
    if (action == null) return '$base · no shortcut (10th+)';
    final chord = ref.watch(keymapProvider).chordFor(action);
    return '$base · ${chord.label}';
  }
}

/// The tabular-numeral member-count badge.
class _CountPill extends StatelessWidget {
  const _CountPill({required this.count, required this.active});

  final int count;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 18),
      padding: const EdgeInsets.symmetric(horizontal: kSpace6, vertical: 1),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$count',
        textAlign: TextAlign.center,
        style: theme.textTheme.labelXs?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
          color: active ? cs.onSurface : cs.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// The per-tab ✕. Kept small so it reads as a secondary affordance next to the
/// label, and carries a kind-specific tooltip (decision 7).
class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.tooltip, required this.onPressed});

  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      iconSize: 11,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
      tooltip: tooltip,
      icon: const Icon(PhosphorIconsLight.x),
      onPressed: onPressed,
    );
  }
}

/// A small pulsing dot marking that a member session is running. Mirrors
/// [SessionStatusDot]'s pulse so "running" reads the same across the app; it
/// only animates while mounted, so an idle group carries no ticking timer.
class _GroupLiveDot extends StatefulWidget {
  const _GroupLiveDot({super.key, required this.color});

  final Color color;

  @override
  State<_GroupLiveDot> createState() => _GroupLiveDotState();
}

class _GroupLiveDotState extends State<_GroupLiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1).animate(_controller),
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}

/// The trailing `+`: a menu offering a new board and the recently-closed board
/// list (decision 8's durable home).
class _NewGroupButton extends ConsumerWidget {
  const _NewGroupButton();

  /// Sentinel value for the "New board…" row (board ids can never collide with
  /// it — they are minted with a `group-` prefix).
  static const String _newBoardValue = '__new_board__';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.only(left: kSpace2, bottom: kSpace4),
      child: IconButton(
        iconSize: 16,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
        tooltip: 'New board or reopen a closed one',
        icon: const Icon(PhosphorIconsLight.plus),
        onPressed: () => _openMenu(context, ref),
      ),
    );
  }

  Future<void> _openMenu(BuildContext context, WidgetRef ref) async {
    final overlay =
        Navigator.of(context).overlay?.context.findRenderObject() as RenderBox?;
    final button = context.findRenderObject() as RenderBox?;
    if (overlay == null || button == null) return;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(
          button.size.bottomLeft(Offset.zero),
          ancestor: overlay,
        ),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );

    final closed = ref.read(groupsControllerProvider).recentlyClosed;
    final live = ref.read(liveSessionIdsProvider);
    final theme = Theme.of(context);

    final selected = await showMenu<String>(
      context: context,
      position: position,
      popUpAnimationStyle: AnimationStyle.noAnimation,
      items: [
        themedMenuItem(
          value: _newBoardValue,
          icon: PhosphorIconsFill.square,
          label: 'New board…',
          color: kBoardSwatch,
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          enabled: false,
          height: kMenuItemHeight,
          child: Text(
            'RECENTLY CLOSED BOARDS',
            style: theme.textTheme.labelXs?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (closed.isEmpty)
          PopupMenuItem<String>(
            enabled: false,
            height: kMenuItemHeight,
            child: Text(
              'Nothing closed yet',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          // Most-recent-first: recentlyClosed is oldest-first (decision 8).
          for (final record in closed.reversed)
            themedMenuItem(
              value: record.group.id,
              icon: PhosphorIconsFill.square,
              color: kBoardSwatch,
              label:
                  '${record.group.label}   '
                  '(${record.group.members.where(live.contains).length} live)',
            ),
      ],
    );

    if (selected == null) return;
    // The bar can be rebuilt or removed while the menu is open (a group closing,
    // the window resizing); the rest of the codebase guards ref use after an
    // await the same way.
    if (!context.mounted) return;
    final controller = ref.read(groupsControllerProvider.notifier);
    if (selected == _newBoardValue) {
      controller.newBoard();
      return;
    }
    controller.reopenBoard(selected, liveSessionIds: live);
  }
}
