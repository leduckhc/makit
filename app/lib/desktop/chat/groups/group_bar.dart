/// SPEC-tab-groups — the group tab strip: a horizontally scrolling rail of group tabs
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
import '../../../ui/widgets/pulse.dart';
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
    // Preview status is identity too (it italicises a tab and adds its Keep
    // item), and it is not part of the string above.
    final previewId = ref.watch(previewGroupIdProvider);

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
                preview: groups[i].id == previewId,
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
    this.preview = false,
  });

  final Group group;

  /// Position in the rail — decides which `⌘N` shortcut the tooltip names.
  final int index;

  final bool active;

  /// SPEC-preview-groups — this is the disposable group: the next branch click replaces it.
  final bool preview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final isBoard = group.kind == GroupKind.board;
    // A worktree group's title is its branch, which can be renamed after the
    // group was minted. The group is keyed by the (stable) worktree path, so
    // resolve the *live* branch from the repos snapshot and only fall back to
    // the stored label when the worktree isn't in the snapshot yet. A board's
    // title is user-owned, so it always uses its stored label.
    final title = isBoard
        ? group.label
        : ref.watch(
                reposProvider.select<String?>(
                  (s) => _liveBranch(s, group.worktreePath),
                ),
              ) ??
              group.label;
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
      child: GestureDetector(
        // Boards are user-named, so a board tab offers Rename on right-click /
        // long-press. A worktree group's label is its branch — not editable, but
        // a *preview* worktree tab offers the Keep gesture (SPEC-preview-groups decision 4).
        onSecondaryTapDown: isBoard || preview
            ? (d) => _showTabMenu(context, ref, d.globalPosition)
            : null,
        onLongPressStart: isBoard || preview
            ? (d) => _showTabMenu(context, ref, d.globalPosition)
            : null,
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
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: active ? cs.onSurface : cs.onSurfaceVariant,
                        // Italic = disposable, borrowed from VSCode's preview
                        // tab: the one signal users already read this way.
                        fontStyle: preview ? FontStyle.italic : null,
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
      ),
    );
  }

  /// Right-click / long-press menu: Rename for a **board**, Keep for a
  /// **preview** worktree tab (SPEC-preview-groups decision 4). One menu rather than two
  /// builders, so a tab that is both offers both items in a fixed order.
  Future<void> _showTabMenu(
    BuildContext context,
    WidgetRef ref,
    Offset globalPosition,
  ) async {
    final overlay = Navigator.of(context).overlay;
    if (overlay == null) return;
    final box = overlay.context.findRenderObject();
    if (box is! RenderBox) return;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(globalPosition, globalPosition),
        Offset.zero & box.size,
      ),
      popUpAnimationStyle: AnimationStyle.noAnimation,
      items: [
        if (preview)
          themedMenuItem(
            value: 'keep',
            icon: PhosphorIconsLight.pushPin,
            label: 'Keep this view',
          ),
        if (group.kind == GroupKind.board)
          themedMenuItem(
            value: 'rename',
            icon: PhosphorIconsLight.pencilSimple,
            label: 'Rename board',
          ),
      ],
    );
    if (selected == 'keep') {
      if (!context.mounted) return;
      ref.read(groupsControllerProvider.notifier).keepGroup(group.id);
      return;
    }
    if (selected != 'rename' || !context.mounted) return;
    await _promptRename(context, ref);
  }

  /// Prompts for a new board name and applies it. Empty/unchanged is a no-op
  /// (the controller enforces this too).
  Future<void> _promptRename(BuildContext context, WidgetRef ref) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => _RenameBoardDialog(initial: group.label),
    );
    if (newName == null || !context.mounted) return;
    ref.read(groupsControllerProvider.notifier).renameBoard(group.id, newName);
  }

  /// The tab's tooltip: what the group is, plus its shortcut. The first nine
  /// name `⌘N` (the live keymap chord); the tenth onward say so explicitly
  /// (decision 16).
  String _tabTooltip(WidgetRef ref) {
    final base = group.kind == GroupKind.worktree
        ? preview
              // Say what will happen and how to stop it: the italic alone does
              // not tell you the next branch click will take this slot.
              ? 'Preview — the next branch you open replaces this tab. '
                    'Click this branch again, or right-click → Keep this view.'
              : 'Worktree group — membership follows the branch'
        : 'Board — hand-picked, can span repos';
    final action = ShortcutAction.switchGroupAtIndex(index);
    if (action == null) return '$base · no shortcut (10th+)';
    final chord = ref.watch(keymapProvider).chordFor(action);
    return '$base · ${chord.label}';
  }
}

/// The board-rename dialog. Owns its [TextEditingController] so it is disposed
/// only after the route is gone (a controller shared with an ad-hoc builder
/// would be used-after-dispose while the dialog animates out).
class _RenameBoardDialog extends StatefulWidget {
  const _RenameBoardDialog({required this.initial});

  final String initial;

  @override
  State<_RenameBoardDialog> createState() => _RenameBoardDialogState();
}

class _RenameBoardDialogState extends State<_RenameBoardDialog> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_ctrl.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename board'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        onSubmitted: (_) => _submit(),
        decoration: const InputDecoration(border: OutlineInputBorder()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Rename')),
      ],
    );
  }
}

/// The live branch of the worktree at [worktreePath] in the repos snapshot, or
/// null when it isn't listed. Used to keep a worktree group's tab title in sync
/// with a branch rename (the group is keyed by path, which the rename leaves
/// unchanged, so the stored label would otherwise go stale).
String? _liveBranch(ReposState repos, String? worktreePath) {
  if (worktreePath == null) return null;
  for (final r in repos.repos) {
    for (final wt in r.worktrees) {
      if (wt.path == worktreePath) return wt.branch;
    }
  }
  return null;
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
class _GroupLiveDot extends StatelessWidget {
  const _GroupLiveDot({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    // Shared low-rate clock: pulsing at the display refresh rate used to pull
    // the whole tab strip's text through re-raster on every vsync.
    return PulseBuilder(
      builder: (context, t) => Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.35 + 0.65 * t),
          shape: BoxShape.circle,
        ),
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
