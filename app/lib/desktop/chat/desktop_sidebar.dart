import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/connection.dart';
import '../../store/models.dart';
import '../../store/ports.dart';
import '../../store/store.dart';
import '../../ui/home/repo_chips.dart';
import '../../ui/ports/ports_popover.dart';
import '../../ui/widgets/lands_in_picker.dart';
import '../../ui/ports/session_ports_glyph.dart';
import '../../ui/widgets/pr_state_style.dart';
import '../../ui/project/folder_browser.dart';
import '../../ui/widgets/connection_chip.dart';
import '../desktop_ports_route.dart';
import '../../status/status_event.dart';
import '../../status/status_providers.dart';
import '../metrics/metrics_button.dart';
import 'closed_sidebar_view.dart';
import 'connection_endpoint.dart';
import 'github_budget_button.dart';
import 'groups/group.dart';
import 'groups/group_providers.dart';
import 'groups/groups_controller.dart';
import 'new_worktree_dialog.dart';
import 'selected_session.dart';
import 'server_profile_badge.dart';
import '../../ui/widgets/session_status_dot.dart';
import 'split_view.dart' show SessionDragData;
import 'title_bar_strip.dart';

/// The left pane of the desktop two-pane chat. Mirrors the mobile repo-centric
/// home (SPEC-11): repos → worktrees (branch, diff stats, open PR) → the
/// sessions bound to each worktree. Footer shows the connection status + a hook
/// for the Settings/Server section.
class DesktopSidebar extends ConsumerWidget {
  /// Creates the sidebar.
  const DesktopSidebar({super.key, this.onOpenSettings});

  /// Invoked when the user opens the Settings/Server section (Unit E wires the
  /// existing control-panel screens here). Null hides the button.
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repos = ref.watch(reposProvider).repos;
    final sessions = ref.watch(sessionsProvider);
    final selected = ref.watch(selectedSessionProvider);
    final closed = ref.watch(sidebarClosedProvider);
    final cs = Theme.of(context).colorScheme;

    return Material(
      color: cs.surfaceContainer,
      child: Column(
        children: [
          const _Header(),
          Expanded(
            child: closed
                ? const ClosedSidebarView()
                : repos.isEmpty
                ? const _EmptySidebar()
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: kSpace8),
                    children: [
                      for (final repo in repos)
                        _RepoGroup(
                          repo: repo,
                          sessions: sessions.forProject(repo.id),
                          selectedId: selected,
                          onSelect: (id) => selectSessionExclusive(ref, id),
                        ),
                    ],
                  ),
          ),
          const Divider(height: 1),
          _Footer(onOpenSettings: onOpenSettings),
        ],
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The OS titlebar is hidden (TitleBarStyle.hidden), so this strip is the
    // window's drag handle. Its height clears the macOS traffic-light buttons
    // that overlay the top-left corner. The fold button sits just to the right
    // of the traffic lights and hides the sidebar entirely; Activity sits next
    // to it, so the app's own voice lives in the chrome rather than at the far
    // end of the footer's telemetry row.
    return const TitleBarStrip(
      leading: SidebarToggleControls(collapse: true),
      trailing: Padding(
        padding: EdgeInsets.only(right: 8),
        child: ServerProfileBadge(),
      ),
    );
  }
}

/// One repo section: header row (name + current branch + stats), then its
/// worktrees with their sessions, then any pending draft sessions.
class _RepoGroup extends ConsumerStatefulWidget {
  const _RepoGroup({
    required this.repo,
    required this.sessions,
    required this.selectedId,
    required this.onSelect,
  });

  final RepoInfo repo;
  final List<Session> sessions;
  final String? selectedId;
  final void Function(String id) onSelect;

  @override
  ConsumerState<_RepoGroup> createState() => _RepoGroupState();
}

class _RepoGroupState extends ConsumerState<_RepoGroup> {
  /// How many worktrees to show before the "show more" pill kicks in.
  static const int _maxCollapsed = 5;
  bool _showAll = false;

  /// Whether the repo group is expanded. Clicking the header row toggles it;
  /// when collapsed the worktrees and the "show more" pill are hidden.
  bool _expanded = true;

  /// Whether the pointer is over the repo header row. Gates the repo actions
  /// menu, mirroring the worktree row's overflow menu.
  bool _repoHovering = false;

  /// Whether the repo header's expand toggle holds keyboard focus. Also gates
  /// the repo actions menu so it stays reachable without a pointer (keyboard /
  /// non-hover input), mirroring the worktree row's `_focused` handling.
  bool _repoFocused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repo = widget.repo;
    // Exited sessions are hidden from the sidebar's repo groups — but only the
    // truly dead ones. A cold, RESUMABLE session (e.g. every session right
    // after a server restart, before re-attach) stays visible so it remains
    // discoverable and can be reopened (it auto-attaches on subscribe).
    // Closed sessions live in the Closed view. Drafts + live sessions stay.
    final sessions = widget.sessions
        .where((s) => s.status != SessionStatus.exited || s.resumable)
        .toList();
    final selectedId = widget.selectedId;
    final onSelect = widget.onSelect;
    final byId = {for (final s in sessions) s.id: s};
    final worktrees = sortWorktreesForDisplay(repo.worktrees);
    final showMore = worktrees.length > _maxCollapsed;
    final visible = (_showAll || !showMore)
        ? worktrees
        : worktrees.take(_maxCollapsed).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 1),
          child: MouseRegion(
            onEnter: (_) => setState(() => _repoHovering = true),
            onExit: (_) => setState(() => _repoHovering = false),
            child: Material(
              type: MaterialType.transparency,
              // Whole row is one inset pill (matches the worktree/session rows):
              // the hover background spans folder + name + caret + the actions,
              // instead of covering only the name.
              child: InkWell(
                borderRadius: BorderRadius.circular(kRadius10),
                onTap: () => setState(() => _expanded = !_expanded),
                onFocusChange: (f) => setState(() => _repoFocused = f),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
                  child: Row(
                    children: [
                      Icon(
                        PhosphorIconsLight.folder,
                        size: 16,
                        color: theme.colorScheme.outline,
                      ),
                      const SizedBox(width: kSpace8),
                      Expanded(
                        child: Text(
                          // Sentence case + bold, not upper-cased with tracking:
                          // the repo is a name, and bold carries the hierarchy
                          // that shouting used to.
                          repo.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.onSurface,
                            fontWeight: FontWeight.w700,
                            // labelMedium carries 0.5 tracking, which exists for
                            // all-caps labels. This is a name now, so drop it.
                            letterSpacing: 0,
                          ),
                        ),
                      ),
                      // Repo actions (overflow menu + new worktree) reveal
                      // together on hover or keyboard focus, nested inside the
                      // pill; their slot stays reserved so the header text never
                      // reflows. maintainState keeps the menu button mounted
                      // while its popup is open (the modal barrier drops hover).
                      Visibility(
                        visible: _repoHovering || _repoFocused,
                        maintainSize: true,
                        maintainAnimation: true,
                        maintainState: true,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(width: kSpace2),
                            _RepoMenuButton(repo: repo),
                            IconButton(
                              tooltip: 'New worktree',
                              padding: EdgeInsets.zero,
                              iconSize: 16,
                              color: Theme.of(context).colorScheme.onSurface,
                              visualDensity: VisualDensity.compact,
                              constraints: const BoxConstraints(
                                minWidth: 22,
                                minHeight: 22,
                              ),
                              icon: const Icon(
                                PhosphorIconsLight.plus,
                                size: 16,
                              ),
                              // Create a worktree up front (a fresh branch by
                              // default); you pick the harness and write the
                              // first message on the pane you land on.
                              onPressed: () => showNewWorktreeDialog(
                                context,
                                ref,
                                projectId: repo.id,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_expanded) ...[
          for (final wt in visible)
            _WorktreeGroup(
              key: ValueKey(wt.id),
              repo: repo,
              worktree: wt,
              sessions: wt.sessionIds
                  .map((id) => byId[id])
                  .whereType<Session>()
                  .toList(),
              selectedId: selectedId,
              onSelect: onSelect,
            ),
          if (showMore)
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 2, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: InkWell(
                  onTap: () => setState(() => _showAll = !_showAll),
                  borderRadius: BorderRadius.circular(kRadius10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: kSpace8,
                      vertical: 3,
                    ),
                    child: Text(
                      _showAll
                          ? 'Show less'
                          : 'Show ${worktrees.length - _maxCollapsed} more',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }
}

/// Width reserved for the disclosure caret, so a row without one still lines its
/// branch name up with the rows that have one.
const double _kCaretSlot = 18;

/// The worktree row's disclosure control. Separate from the row's own tap
/// (SPEC-30 decision 15: the row navigates, the caret discloses), so neither
/// gesture has to guess which of the two the user meant.
class _WorktreeCaret extends StatelessWidget {
  const _WorktreeCaret({
    super.key,
    required this.expanded,
    required this.onPressed,
  });

  final bool expanded;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _kCaretSlot,
      height: _kCaretSlot,
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

/// A compact overflow-menu trigger sized to match the sidebar's + button: a
/// [VisualDensity.compact] [IconButton] (so its hover state layer is the small
/// circle the + uses) that opens a popup via [showMenu]. PopupMenuButton's own
/// `icon` can't be shrunk to this size — it wraps the icon in a default 48px
/// IconButton and Material 3 fills that whole box with the hover state layer.
class _CompactMenuButton extends StatelessWidget {
  const _CompactMenuButton({
    required this.icon,
    required this.tooltip,
    required this.itemBuilder,
    required this.onSelected,
    this.onOpened,
  });

  final IconData icon;
  final String tooltip;
  final List<PopupMenuEntry<String>> Function(BuildContext) itemBuilder;

  /// Invoked with the chosen value, or the empty string when the menu is
  /// dismissed without a selection (so callers can clear open-state flags).
  final void Function(String value) onSelected;

  /// Invoked just before the menu opens (parity with PopupMenuButton.onOpened).
  final VoidCallback? onOpened;

  Future<void> _open(BuildContext context) async {
    final button = context.findRenderObject() as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );
    onOpened?.call();
    final selected = await showMenu<String>(
      context: context,
      position: position,
      items: itemBuilder(context),
      popUpAnimationStyle: AnimationStyle.noAnimation,
    );
    // The trigger can unmount while the menu is open (its row/worktree removed);
    // its callbacks touch parent state, so bail if we're gone.
    if (!context.mounted) return;
    onSelected(selected ?? '');
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      // Tightly bounded so hovering never grows the worktree row (which would
      // shift the branch name): the box matches the 16px glyph plus a hair,
      // staying within the row's leading-icon height.
      padding: EdgeInsets.zero,
      iconSize: 16,
      color: Theme.of(context).colorScheme.onSurface,
      constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
      icon: Icon(icon, size: 16),
      onPressed: () => _open(context),
    );
  }
}

/// The repo header's overflow menu (the triple-dots left of +). Hosts repo-
/// scoped actions: hide the repo (untrack it). More items land here later.
class _RepoMenuButton extends ConsumerWidget {
  const _RepoMenuButton({required this.repo});

  final RepoInfo repo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _CompactMenuButton(
      tooltip: 'Repo actions',
      icon: PhosphorIconsRegular.dotsThree,
      onSelected: (value) {
        switch (value) {
          case 'hide':
            _hideRepo(ref);
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'hide',
          height: 36,
          child: Text(
            'Hide the repo',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ),
      ],
    );
  }

  /// Untrack the repo, surfacing failures the way rename/delete do rather than
  /// dropping the rejected command as an unhandled async error.
  Future<void> _hideRepo(WidgetRef ref) async {
    // Resolved before the first await: `ref` throws once its widget is
    // unmounted, and the record must survive the thing that reported to it.
    final status = ref.status;
    try {
      await ref.read(storeControllerProvider.notifier).removeProject(repo.id);
    } catch (e) {
      status.failure(
        'Could not hide the repo',
        error: e,
        source: StatusSources.repo,
      );
    }
  }
}

/// A worktree line (branch + diff, then an optional PR line) with its sessions
/// nested below. Clicking the branch row collapses/expands its sessions.
class _WorktreeGroup extends ConsumerStatefulWidget {
  const _WorktreeGroup({
    super.key,
    required this.repo,
    required this.worktree,
    required this.sessions,
    required this.selectedId,
    required this.onSelect,
  });

  final RepoInfo repo;
  final Worktree worktree;
  final List<Session> sessions;
  final String? selectedId;
  final void Function(String id) onSelect;

  @override
  ConsumerState<_WorktreeGroup> createState() => _WorktreeGroupState();
}

class _WorktreeGroupState extends ConsumerState<_WorktreeGroup> {
  bool _expanded = true;
  bool _hovering = false;
  bool _focused = false;
  // Kept true while the actions popup is open. Opening the menu drops a modal
  // barrier that steals mouse-hover (flipping `_hovering` off), which would
  // otherwise unmount `_WorktreeMenuButton` — and its dialog-owning context —
  // before `onSelected` runs.
  bool _menuOpen = false;
  // OR-ed into the line-1 swap condition below for the SAME reason as
  // `_menuOpen`: opening the ports popover drops a modal-ish barrier / moves the
  // pointer off the row, flipping `_hovering` off — which would snap the `…`
  // menu back to a diff pill under the cursor while the popover is open. The
  // popover reports its open-state through `onOpenChanged` (SPEC-41 §5 trap).
  bool _portsOpen = false;

  // Hold the ref-counted ports watch while any worktree group is mounted in the
  // sidebar, so the server polls `lsof` only while the sidebar is up (SPEC-41
  // §Delivery); the ref-count collapses every mounted group to one
  // `ports.watch {on:true}`.
  late final PortsWatch _portsWatch = ref.read(portsWatchProvider);

  @override
  void initState() {
    super.initState();
    _portsWatch.watch();
  }

  @override
  void dispose() {
    _portsWatch.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repo = widget.repo;
    final worktree = widget.worktree;
    final sessions = widget.sessions;
    final branch = worktree.branch ?? 'detached';
    final isCurrent =
        worktree.branch != null && worktree.branch == repo.currentBranch;
    final worktreeSelected =
        ref.watch(selectedWorktreeProvider)?.path == worktree.path;
    // Glyph + tint per PR state (open / merged / closed / none) — shared with
    // the composer pill and the window title strip.
    final prStyle = prStateStyle(theme.colorScheme, worktree.pr);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MouseRegion(
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) => setState(() => _hovering = false),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: kSpace8,
              vertical: 1,
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: BorderRadius.circular(kRadius10),
                onFocusChange: (f) => setState(() => _focused = f),
                // Decision 15: the row *navigates* — it activates (minting if
                // needed) this worktree's group, and an empty scope also seeds
                // the in-pane starter. It deliberately does NOT toggle
                // disclosure: one tap doing both meant peeking at a branch's
                // children yanked the canvas, and moving the canvas collapsed
                // the row you were reading. The caret owns disclosure.
                onTap: () => selectWorktree(
                  ref,
                  SelectedWorktree(
                    projectId: repo.id,
                    path: worktree.path,
                    branch: worktree.branch,
                  ),
                ),
                child: Ink(
                  decoration: BoxDecoration(
                    color: worktreeSelected
                        ? theme.colorScheme.surfaceContainerHighest
                        : null,
                    borderRadius: BorderRadius.circular(kRadius10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(6, 6, 8, 2),
                        child: Row(
                          children: [
                            // Disclosure. Only rows that have something to show
                            // get one, so an empty worktree does not offer a
                            // control that would do nothing; its slot is kept so
                            // branch names stay aligned down the column.
                            if (sessions.isEmpty)
                              const SizedBox(width: _kCaretSlot)
                            else
                              _WorktreeCaret(
                                key: Key('worktreeCaret-${worktree.path}'),
                                expanded: _expanded,
                                onPressed: () =>
                                    setState(() => _expanded = !_expanded),
                              ),
                            prStyle.glyph.build(size: 16, color: prStyle.color),
                            const SizedBox(width: kSpace6),
                            Expanded(
                              child: Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      branch,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ),
                                  if (isCurrent) ...[
                                    const SizedBox(width: 5),
                                    Icon(
                                      PhosphorIconsFill.star,
                                      size: 8,
                                      color: theme.colorScheme.outline,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(width: kSpace8),
                            // On hover or keyboard focus the diff pill is replaced
                            // by the worktree overflow menu (rename / delete), so
                            // the actions are reachable without a pointer. Otherwise
                            // it shows the diff stats (when the tree has changes).
                            if (_hovering ||
                                _focused ||
                                _menuOpen ||
                                _portsOpen)
                              _WorktreeMenuButton(
                                worktree: worktree,
                                onMenuOpened: () =>
                                    setState(() => _menuOpen = true),
                                onSelected: (action) {
                                  setState(() => _menuOpen = false);
                                  switch (action) {
                                    case 'rename':
                                      _renameBranch();
                                    case 'landsIn':
                                      // NOT `sheet: true`: desktop wants the
                                      // dialog form of the picker, not a bottom
                                      // sheet. It persists the choice itself.
                                      unawaited(
                                        showLandsInPicker(
                                          context,
                                          ref,
                                          projectId: repo.id,
                                          worktree: worktree,
                                        ),
                                      );
                                    case 'delete':
                                      _deleteWorktree();
                                    case 'ports':
                                      // D8: explicit navigation to the global
                                      // Ports screen pre-filtered to this repo —
                                      // never a lift of the popover's private
                                      // open/pinned controller. Pushed on this
                                      // shell's Navigator: the desktop window is
                                      // not a router app (desktop_ports_route.dart).
                                      unawaited(
                                        DesktopPortsRoute.open(
                                          Navigator.of(context),
                                          repoId: repo.id,
                                        ),
                                      );
                                  }
                                },
                              )
                            // See worktree_row.dart: suppress rather than
                            // publish a partial count.
                            else if (worktree.showsDiff)
                              DiffChip(
                                insertions: worktree.insertions,
                                deletions: worktree.deletions,
                              ),
                          ],
                        ),
                      ),
                      // Sub-row below the branch, inside the same hover/tap group: the
                      // PR number label (when present) followed by the low-emphasis
                      // branch age. Fixed height so the row always reserves its place.
                      Padding(
                        padding: const EdgeInsets.fromLTRB(46, 0, 8, 4),
                        child: SizedBox(
                          height: 16,
                          child: Row(
                            children: [
                              Expanded(
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (worktree.pr != null) ...[
                                        Text(
                                          'PR #${worktree.pr!.number}',
                                          style: theme.textTheme.labelSmall
                                              ?.copyWith(
                                                color:
                                                    theme.colorScheme.outline,
                                                fontWeight: FontWeight.w300,
                                              ),
                                        ),
                                        const SizedBox(width: kSpace4),
                                        Text(
                                          '•',
                                          style: theme.textTheme.labelSmall
                                              ?.copyWith(
                                                color:
                                                    theme.colorScheme.outline,
                                                fontWeight: FontWeight.w300,
                                              ),
                                        ),
                                        const SizedBox(width: kSpace4),
                                      ],
                                      Text(
                                        branchAgeLabel(worktree.committedAt),
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                              color: theme.colorScheme.outline,
                                              fontWeight: FontWeight.w300,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              // Ports glyph, right-aligned on the same 8 pt edge
                              // as line 1's swap (SPEC-41 §5). 14 pt glyph in a
                              // 22 × 16 target: wider than tall, so the fixed
                              // 16 pt sub-row does NOT grow. Renders nothing when
                              // the branch is serving nothing.
                              _SubRowPortsGlyph(
                                worktreePath: worktree.path,
                                branch: branch,
                                onOpenChanged: (open) =>
                                    setState(() => _portsOpen = open),
                              ),
                            ],
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
        if (_expanded)
          for (final s in sessions)
            _SessionTile(
              session: s,
              selected: s.id == widget.selectedId,
              indented: true,
              onTap: () => widget.onSelect(s.id),
            ),
      ],
    );
  }

  Future<void> _renameBranch() async {
    // Resolved before the first await: `ref` throws once its widget is
    // unmounted, and the record must survive the thing that reported to it.
    final status = ref.status;
    final repo = widget.repo;
    final worktree = widget.worktree;
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => _RenameBranchDialog(initial: worktree.branch ?? ''),
    );
    if (newName == null || newName.isEmpty || newName == worktree.branch) {
      return;
    }
    try {
      await ref
          .read(storeControllerProvider.notifier)
          .renameBranch(repo.id, worktree.path, newName);
    } catch (e) {
      status.failure(
        'Could not rename the branch',
        error: e,
        source: StatusSources.worktree,
      );
    }
  }

  Future<void> _deleteWorktree() async {
    // Resolved before the first await: `ref` throws once its widget is
    // unmounted, and the record must survive the thing that reported to it.
    final status = ref.status;
    final repo = widget.repo;
    final worktree = widget.worktree;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete worktree'),
        content: Text(
          'Delete the worktree for "${worktree.branch ?? worktree.path}"? '
          'Uncommitted changes will be lost and any running sessions in it '
          'will be stopped.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref
          .read(storeControllerProvider.notifier)
          .removeWorktree(repo.id, worktree.path);
    } catch (e) {
      status.failure(
        'Could not delete the worktree',
        error: e,
        source: StatusSources.worktree,
      );
    }
  }
}

/// The worktree row's hover overflow menu (triple dots that replace the diff
/// pill on hover). Reports the chosen action up to [_WorktreeGroupState], which
/// owns the dialogs and store calls with a context/ref that outlives the menu.
/// "Rename branch", "Lands in" and "Delete worktree" are disabled for the
/// primary worktree and for detached worktrees; "Rename branch" is additionally
/// disabled for an open PR, but "Lands in" is NOT (retargeting an open PR is a
/// first-class operation). Because this menu replaces the diff pill on hover,
/// "Lands in" prints the current target inline — the pill is not visible to
/// glance at while the menu is open.
class _WorktreeMenuButton extends ConsumerWidget {
  const _WorktreeMenuButton({
    required this.worktree,
    required this.onMenuOpened,
    required this.onSelected,
  });

  final Worktree worktree;
  final VoidCallback onMenuOpened;
  final void Function(String action) onSelected;

  bool get _hasOpenPr => worktree.pr?.state.toUpperCase() == 'OPEN';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPrimary = worktree.isPrimary;
    final isDetached = worktree.branch == null;
    final canRename = !_hasOpenPr && !isPrimary && !isDetached;
    // Retargeting shares rename's structural guards (no primary, no detached)
    // but pointedly NOT its open-PR block: renaming orphans a PR's head, while
    // retargeting an open PR is a first-class operation (`gh pr edit --base`).
    // So an open PR leaves this enabled while it disables Rename — deliberate.
    final canRetarget = !isPrimary && !isDetached;
    // The count is a glance at what this branch is serving; the item routes to
    // the global Ports screen either way (D8), so it shows even at zero.
    final portCount = ref.watch(portsForWorktreeProvider(worktree.path)).length;
    return _CompactMenuButton(
      tooltip: 'Worktree actions',
      icon: PhosphorIconsRegular.dotsThree,
      onOpened: onMenuOpened,
      // A cancelled menu resolves to null → forward '' so the parent's
      // "keep mounted while open" flag is cleared just like a real selection.
      onSelected: onSelected,
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'rename',
          enabled: canRename,
          height: 36,
          child: Tooltip(
            message: isPrimary
                ? "Can't rename the primary worktree's branch"
                : isDetached
                ? "Can't rename a detached worktree (no branch)"
                : _hasOpenPr
                ? "Can't rename a branch with an open pull request"
                : '',
            child: Text(
              'Rename branch',
              // Match PopupMenuItem's disabled greying (it tints the child's
              // DefaultTextStyle with disabledColor): keep bodyMedium's size
              // but hand the color back to the disabled default when disabled.
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: canRename ? null : Theme.of(context).disabledColor,
              ),
            ),
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'landsIn',
          enabled: canRetarget,
          height: 36,
          child: Tooltip(
            message: isPrimary
                ? 'This is where branches land, not one that lands'
                : isDetached
                ? 'This worktree has no branch to land'
                : '',
            // Bare Text + a trailing value, no leading icon — matching the
            // other items in this menu. The `⋯` button REPLACES the diff pill
            // on hover, so the user cannot glance back at the pill for the
            // current target while this menu is open; the item prints its own
            // current value on the right instead.
            child: Row(
              children: [
                Text(
                  'Lands in',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: canRetarget ? null : Theme.of(context).disabledColor,
                  ),
                ),
                const Spacer(),
                if (worktree.targetBranch != null) ...[
                  const SizedBox(width: kSpace12),
                  Flexible(
                    child: Text(
                      worktree.targetBranch!,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.mono
                          .copyWith(
                            color: canRetarget
                                ? Theme.of(context).colorScheme.outline
                                : Theme.of(context).disabledColor,
                          ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'delete',
          enabled: !isPrimary,
          height: 36,
          child: Tooltip(
            message: isPrimary ? "Can't delete the primary worktree" : '',
            child: Text(
              'Delete worktree',
              // Destructive: tint red when enabled; when disabled (primary),
              // fall back to disabledColor so it greys like PopupMenuItem's
              // default disabled child rather than reading as an active item.
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: isPrimary
                    ? Theme.of(context).disabledColor
                    : Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'ports',
          height: 36,
          child: Text(
            'Ports ($portCount)…',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }
}

/// The worktree sub-row's ports glyph (SPEC-41 §5), desktop form. A 14 pt glyph
/// in a fixed 22 × 16 hit target — wider, not taller — so the sub-row keeps its
/// reserved 16 pt height. Hit testing is bounded by this box (Flutter clips to
/// the parent), so the target is honestly 22 × 16, not 22 × 22. Renders nothing
/// when the branch is serving nothing.
class _SubRowPortsGlyph extends ConsumerWidget {
  const _SubRowPortsGlyph({
    required this.worktreePath,
    required this.branch,
    required this.onOpenChanged,
  });

  final String worktreePath;
  final String branch;
  final ValueChanged<bool> onOpenChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(portsGlyphStateProvider(worktreePath));
    if (state == PortsGlyphState.none) return const SizedBox.shrink();
    final ports = ref.watch(portsForWorktreeProvider(worktreePath));
    return SizedBox(
      key: ValueKey('portsSubRowTarget-$worktreePath'),
      width: 22,
      height: 16,
      child: Center(
        child: PortsPopover(
          state: state,
          count: ports.length,
          branch: branch,
          ports: ports,
          nowMs: DateTime.now().millisecondsSinceEpoch,
          onOpenChanged: onOpenChanged,
        ),
      ),
    );
  }
}

/// The rename-branch dialog. Owns its [TextEditingController] as a State field
/// so it is disposed only after the route is fully removed — disposing it the
/// moment `showDialog` returns would crash the dialog's exit animation, which
/// still rebuilds the [TextField].
class _RenameBranchDialog extends StatefulWidget {
  const _RenameBranchDialog({required this.initial});

  final String initial;

  @override
  State<_RenameBranchDialog> createState() => _RenameBranchDialogState();
}

class _RenameBranchDialogState extends State<_RenameBranchDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename branch'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'New branch name'),
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Rename'),
        ),
      ],
    );
  }
}

class _SessionTile extends ConsumerStatefulWidget {
  const _SessionTile({
    required this.session,
    required this.selected,
    required this.onTap,
    this.indented = false,
  });

  final Session session;
  final bool selected;
  final bool indented;
  final VoidCallback onTap;

  @override
  ConsumerState<_SessionTile> createState() => _SessionTileState();
}

class _SessionTileState extends ConsumerState<_SessionTile> {
  bool _hovering = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = widget.session;
    final selected = widget.selected;
    final indented = widget.indented;
    final onTap = widget.onTap;
    final title = session.pending && session.title.trim().isEmpty
        ? 'new worktree'
        : (session.title.trim().isNotEmpty
              ? session.title.trim()
              : (session.agent.trim().isNotEmpty ? session.agent : session.id));

    // Board-membership affordances (decisions 14 & 15): a violet pin dot marks
    // a member, and a hover `+` quick-pins a non-member — but only while a
    // board is the active group, since only a board has a curated list to add
    // to. A worktree group's membership is derived, so it has no quick-pin.
    // Narrow watches on purpose. `activeGroupProvider` yields the whole Group,
    // whose `==` includes its tree, and `commitTree` rewrites that on every
    // focus/split/tab change — watching it here rebuilt EVERY session tile on
    // every canvas mutation. Only the active group's kind and id matter.
    final boardActive = ref.watch(
      groupsControllerProvider.select<bool>(
        (s) => s.active.kind == GroupKind.board,
      ),
    );
    final activeGroupId = ref.watch(
      groupsControllerProvider.select<String>((s) => s.active.id),
    );
    final isMember =
        boardActive &&
        ref.watch(
          groupMembersProvider(
            activeGroupId,
          ).select<bool>((members) => members.contains(session.id)),
        );
    final Widget? trailing = !boardActive
        ? null
        : isMember
        ? const Icon(PhosphorIconsFill.circle, size: 10, color: kBoardSwatch)
        : (_hovering || _focused
              ? IconButton(
                  key: const Key('sidebarQuickPin'),
                  tooltip: 'Pin to this board',
                  padding: EdgeInsets.zero,
                  iconSize: 14,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 22,
                    minHeight: 22,
                  ),
                  color: kBoardSwatch,
                  icon: const Icon(PhosphorIconsLight.plus, size: 14),
                  onPressed: () => ref
                      .read(groupsControllerProvider.notifier)
                      .addMember(
                        activeGroupId,
                        session.id,
                        location: locationOf(session),
                      ),
                )
              : null);

    final tile = Padding(
      padding: const EdgeInsets.symmetric(horizontal: kSpace8),
      child: ListTile(
        dense: true,
        // Keyboard/touch reachability: the quick-pin reveals on focus as well
        // as hover (matching the repo header and worktree row), so it isn't
        // pointer-only.
        onFocusChange: (f) => setState(() => _focused = f),
        visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
        minVerticalPadding: 0,
        minTileHeight: 24,
        selected: selected,
        selectedTileColor: theme.colorScheme.surfaceContainerHighest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadius10),
        ),
        contentPadding: EdgeInsets.only(left: indented ? 24 : 8, right: 12),
        title: Row(
          children: [
            // Leading status dot sized to the branch-icon column, so a session
            // lines up under its worktree's icon and the title sits under the
            // branch name. Idle sessions reserve the slot but show no dot.
            SizedBox(
              width: 16,
              child: Center(
                child: session.status == SessionStatus.idle
                    ? const SizedBox.shrink()
                    : SessionStatusDot(status: session.status),
              ),
            ),
            const SizedBox(width: kSpace6),
            Expanded(
              // xs (10px): a session title is a dense list entry, not body copy,
              // and the row is sized to match rather than keeping ListTile's
              // default height around a much smaller label.
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(fontSize: 10),
              ),
            ),
            // The session's own ports glyph (D14): quiet, renders only when a
            // listener is attributed to this session.
            SessionPortsGlyph(sessionId: session.id),
          ],
        ),
        trailing: trailing,
        onTap: onTap,
      ),
    );
    // Drag a session onto a pane to open/move it there. Horizontal affinity so
    // a normal vertical drag still scrolls the sidebar; a rightward pull (into
    // the panes) starts the drag.
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Draggable<SessionDragData>(
        data: SessionDragData(session.id),
        affinity: Axis.horizontal,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: _SessionDragFeedback(title: title, status: session.status),
        childWhenDragging: Opacity(opacity: 0.4, child: tile),
        child: tile,
      ),
    );
  }
}

/// The chip shown under the pointer while dragging a session out of the
/// sidebar (a compact title + status dot on the accent surface).
class _SessionDragFeedback extends StatelessWidget {
  const _SessionDragFeedback({required this.title, required this.status});

  final String title;
  final SessionStatus status;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: kSpace10,
          vertical: kSpace6,
        ),
        constraints: const BoxConstraints(maxWidth: 220),
        decoration: BoxDecoration(
          color: cs.primaryContainer,
          borderRadius: BorderRadius.circular(kRadius8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (status != SessionStatus.idle) ...[
              SessionStatusDot(status: status),
              const SizedBox(width: kSpace6),
            ],
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: cs.onPrimaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Footer extends ConsumerWidget {
  const _Footer({this.onOpenSettings});
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final server = ref.watch(connectionProvider).server;
    final endpoint = formatEndpoint(server?.host, server?.port);
    final theme = Theme.of(context);
    final showClosed = ref.watch(sidebarClosedProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          // Status + endpoint share one Expanded so *all* slack lands here and
          // the trailing icons stay pinned to the right edge. (The chip used to
          // be a flex sibling of the icons, so it claimed a share of the slack
          // it never painted, leaving dead space after the last icon.)
          Expanded(
            child: Row(
              children: [
                const Flexible(child: ConnectionChip()),
                const SizedBox(width: kSpace8),
                if (endpoint != null)
                  Flexible(
                    child: Text(
                      endpoint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const MetricsButton(),
          const GithubBudgetButton(),
          IconButton(
            tooltip: 'Add repo',
            icon: const Icon(PhosphorIconsLight.folderPlus, size: 18),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () => showFolderBrowser(context),
          ),
          IconButton(
            tooltip: showClosed
                ? 'Show active sessions'
                : 'Show closed sessions',
            icon: Icon(
              showClosed
                  ? PhosphorIconsLight.stackSimple
                  : PhosphorIconsLight.moon,
              size: 18,
            ),
            color: showClosed ? theme.colorScheme.primary : null,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () =>
                ref.read(sidebarClosedProvider.notifier).state = !showClosed,
          ),
          if (onOpenSettings != null)
            IconButton(
              tooltip: 'Settings & Server',
              icon: const Icon(PhosphorIconsLight.gearSix, size: 18),
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: onOpenSettings,
            ),
        ],
      ),
    );
  }
}

class _EmptySidebar extends StatelessWidget {
  const _EmptySidebar();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(kSpace24),
        child: Text(
          'No repos yet.\nUse the + button below\nto add a git repo.',
          textAlign: TextAlign.center,
          style: TextStyle(color: cs.outline),
        ),
      ),
    );
  }
}
