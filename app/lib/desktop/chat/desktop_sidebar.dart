import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import '../../store/models.dart';
import '../../store/store.dart';
import '../../store/connection.dart';
import '../../ui/home/repo_chips.dart';
import '../../ui/widgets/connection_chip.dart';
import '../../ui/project/folder_browser.dart';
import 'connection_endpoint.dart';
import 'session_status_dot.dart';
import 'split_view.dart' show SessionDragData;
import 'title_bar_strip.dart';
import 'server_profile_badge.dart';
import 'new_session_dialog.dart';
import 'archived_sidebar_view.dart';
import 'selected_session.dart';

/// The left pane of the desktop two-pane chat. Mirrors the mobile repo-centric
/// home (SPEC-11): repos → worktrees (branch, diff stats, open PR) → the
/// sessions running in each worktree, plus pending draft sessions that
/// haven't named a branch yet. Footer shows the connection status + a hook for
/// the Settings/Server section.
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
    final archived = ref.watch(sidebarArchivedProvider);
    final cs = Theme.of(context).colorScheme;

    return Material(
      color: cs.surfaceContainer,
      child: Column(
        children: [
          const _Header(),
          Expanded(
            child: archived
                ? const ArchivedSidebarView()
                : repos.isEmpty
                ? const _EmptySidebar()
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
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
    // of the traffic lights and hides the sidebar entirely.
    return const TitleBarStrip(
      leading: SidebarToggleButton(collapse: true),
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
  /// when collapsed the worktrees, "show more" pill, and drafts are hidden.
  bool _expanded = true;

  /// Whether the pointer is over the repo header row. Gates the repo actions
  /// menu, mirroring the worktree row's overflow menu.
  bool _repoHovering = false;

  /// Whether the repo header's expand toggle holds keyboard focus. Also gates
  /// the repo actions menu so it stays reachable without a pointer (keyboard /
  /// non-hover input), mirroring the worktree row's `_focused` handling.
  bool _repoFocused = false;

  /// True while a draft spawn is in flight, so rapid clicks on the + button
  /// can't issue concurrent `spawnSession` calls (duplicate pending worktrees).
  bool _spawningDraft = false;

  /// The sidebar + button: spawn a pending draft (no worktree on disk yet) and
  /// open it in its own virtual pane tree, landing on the harness picker. The
  /// real worktree materializes on the draft's first message. No dialog — the
  /// richer "New worktree from…" picker lives in the repo overflow menu.
  Future<void> _startDraftWorktree(String projectId) async {
    if (_spawningDraft) return;
    setState(() => _spawningDraft = true);
    final store = ref.read(storeControllerProvider.notifier);
    try {
      final sid = await store.spawnSession(projectId);
      if (!mounted) return;
      openDraftSession(ref, sid);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('New worktree failed: $e')));
    } finally {
      if (mounted) setState(() => _spawningDraft = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repo = widget.repo;
    // Exited sessions are hidden from the sidebar's repo groups — but only the
    // truly dead ones. A cold, RESUMABLE session (e.g. every session right
    // after a server restart, before re-attach) stays visible so it remains
    // discoverable and can be reopened (it auto-attaches on subscribe).
    // Archived sessions live in the Archived view. Drafts + live sessions stay.
    final sessions = widget.sessions
        .where((s) => s.status != SessionStatus.exited || s.resumable)
        .toList();
    final selectedId = widget.selectedId;
    final onSelect = widget.onSelect;
    final drafts = sessions.where((s) => s.pending).toList();
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
                borderRadius: BorderRadius.circular(10),
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
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          repo.name.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.outline,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.8,
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
                            const SizedBox(width: 2),
                            _RepoMenuButton(repo: repo),
                            IconButton(
                              tooltip: 'New worktree',
                              padding: EdgeInsets.zero,
                              iconSize: 16,
                              visualDensity: VisualDensity.compact,
                              constraints: const BoxConstraints(
                                minWidth: 22,
                                minHeight: 22,
                              ),
                              icon: const Icon(
                                PhosphorIconsLight.plus,
                                size: 16,
                              ),
                              onPressed: _spawningDraft
                                  ? null
                                  : () => _startDraftWorktree(repo.id),
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
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
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
          for (final s in drafts)
            _DraftWorktreeTile(
              session: s,
              selected: s.id == selectedId,
              onTap: () => onSelect(s.id),
            ),
        ],
      ],
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
      constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
      icon: Icon(icon, size: 16),
      onPressed: () => _open(context),
    );
  }
}

/// The repo header's overflow menu (the triple-dots left of +). Hosts repo-
/// scoped actions: hide the repo (untrack it) and open the richer
/// "New worktree from…" dialog. More items land here later.
class _RepoMenuButton extends ConsumerWidget {
  const _RepoMenuButton({required this.repo});

  final RepoInfo repo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _CompactMenuButton(
      tooltip: 'Repo actions',
      icon: PhosphorIconsLight.dotsThree,
      onSelected: (value) {
        switch (value) {
          case 'hide':
            _hideRepo(context, ref);
          case 'new-worktree':
            showNewSessionDialog(context, ref, projectId: repo.id);
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'new-worktree',
          child: Text('New worktree from…'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'hide',
          child: Text(
            'Hide the repo',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ],
    );
  }

  /// Untrack the repo, surfacing failures the way rename/delete do rather than
  /// dropping the rejected command as an unhandled async error.
  Future<void> _hideRepo(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(storeControllerProvider.notifier).removeProject(repo.id);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Hide failed: $e')));
      }
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repo = widget.repo;
    final worktree = widget.worktree;
    final sessions = widget.sessions;
    final branch = worktree.branch ?? 'detached';
    final isCurrent =
        worktree.branch != null && worktree.branch == repo.currentBranch;
    // A worktree with no sessions is selectable: clicking it opens the harness
    // picker in the pane to start a session in this existing worktree.
    final selectable = sessions.isEmpty;
    final worktreeSelected =
        ref.watch(selectedWorktreeProvider)?.path == worktree.path;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MouseRegion(
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) => setState(() => _hovering = false),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onFocusChange: (f) => setState(() => _focused = f),
                onTap: () {
                  if (selectable) {
                    selectWorktree(
                      ref,
                      SelectedWorktree(
                        projectId: repo.id,
                        path: worktree.path,
                        branch: worktree.branch,
                      ),
                    );
                  } else {
                    setState(() => _expanded = !_expanded);
                  }
                },
                child: Ink(
                  decoration: BoxDecoration(
                    color: worktreeSelected
                        ? theme.colorScheme.surfaceContainerHighest
                        : null,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 6, 8, 2),
                        child: Row(
                          children: [
                            // Open PR → the merge symbol; otherwise the plain
                            // worktree/branch icon that predated the PR-centric
                            // redesign (still used by the draft-worktree tile and
                            // any non-open PR).
                            if (worktree.pr?.state.toUpperCase() == 'OPEN')
                              Icon(
                                PhosphorIconsLight.gitPullRequest,
                                size: 16,
                                color: theme.colorScheme.primary,
                              )
                            else
                              Icon(
                                PhosphorIconsLight.gitBranch,
                                size: 16,
                                color: theme.colorScheme.outline,
                              ),
                            const SizedBox(width: 6),
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
                            const SizedBox(width: 8),
                            // On hover or keyboard focus the diff pill is replaced
                            // by the worktree overflow menu (rename / delete), so
                            // the actions are reachable without a pointer. Otherwise
                            // it shows the diff stats (when the tree has changes).
                            if (_hovering || _focused || _menuOpen)
                              _WorktreeMenuButton(
                                worktree: worktree,
                                onMenuOpened: () =>
                                    setState(() => _menuOpen = true),
                                onSelected: (action) {
                                  setState(() => _menuOpen = false);
                                  switch (action) {
                                    case 'rename':
                                      _renameBranch();
                                    case 'delete':
                                      _deleteWorktree();
                                  }
                                },
                              )
                            else if (worktree.hasChanges)
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
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (worktree.pr != null) ...[
                                  Text(
                                    'PR #${worktree.pr!.number}',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.outline,
                                      fontWeight: FontWeight.w300,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '•',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.outline,
                                      fontWeight: FontWeight.w300,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                ],
                                Text(
                                  _branchAgeLabel(worktree.committedAt),
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.outline,
                                    fontWeight: FontWeight.w300,
                                  ),
                                ),
                              ],
                            ),
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
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Rename failed: $e')));
      }
    }
  }

  Future<void> _deleteWorktree() async {
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
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }
}

/// The worktree row's hover overflow menu (triple dots that replace the diff
/// pill on hover). Reports the chosen action up to [_WorktreeGroupState], which
/// owns the dialogs and store calls with a context/ref that outlives the menu.
/// "Rename branch" and "Delete worktree" are disabled for the primary worktree;
/// "Rename branch" is also disabled for detached worktrees and open PRs.
class _WorktreeMenuButton extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final isPrimary = worktree.isPrimary;
    final isDetached = worktree.branch == null;
    final canRename = !_hasOpenPr && !isPrimary && !isDetached;
    return _CompactMenuButton(
      tooltip: 'Worktree actions',
      icon: PhosphorIconsLight.dotsThree,
      onOpened: onMenuOpened,
      // A cancelled menu resolves to null → forward '' so the parent's
      // "keep mounted while open" flag is cleared just like a real selection.
      onSelected: onSelected,
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'rename',
          enabled: canRename,
          child: Tooltip(
            message: isPrimary
                ? "Can't rename the primary worktree's branch"
                : isDetached
                ? "Can't rename a detached worktree (no branch)"
                : _hasOpenPr
                ? "Can't rename a branch with an open pull request"
                : '',
            child: const Text('Rename branch'),
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'delete',
          enabled: !isPrimary,
          child: Tooltip(
            message: isPrimary ? "Can't delete the primary worktree" : '',
            child: Text(
              'Delete worktree',
              // Destructive: tint red, but only when actually enabled so a
              // disabled item keeps its greyed-out affordance.
              style: isPrimary
                  ? null
                  : TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ),
      ],
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

/// A pending draft rendered to match a worktree row. The worktree doesn't
/// exist yet, so it shows "new worktree" in place of the branch name and its
/// age counts from when the user clicked New worktree (the draft's creation),
/// since the real worktree creation is postponed until the first message.
class _DraftWorktreeTile extends StatelessWidget {
  const _DraftWorktreeTile({
    required this.session,
    required this.selected,
    required this.onTap,
  });

  final Session session;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final createdAt = session.lastActivityAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(session.lastActivityAt)
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Ink(
            decoration: BoxDecoration(
              color: selected
                  ? theme.colorScheme.surfaceContainerHighest
                  : null,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 6, 8, 2),
                  child: Row(
                    children: [
                      Icon(
                        PhosphorIconsLight.gitBranch,
                        size: 16,
                        color: theme.colorScheme.outline,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'new worktree',
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(46, 0, 8, 4),
                  child: SizedBox(
                    height: 16,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _branchAgeLabel(createdAt),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.outline,
                          fontWeight: FontWeight.w300,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Human-readable HEAD-commit age like `3d ago`. Empty string when unknown,
/// so the sub-row below the branch still reserves its vertical space.
String _branchAgeLabel(DateTime? committedAt) {
  if (committedAt == null) return '';
  final d = DateTime.now().difference(committedAt);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 30) return '${d.inDays}d ago';
  if (d.inDays < 365) return '${(d.inDays / 30).floor()}mo ago';
  return '${(d.inDays / 365).floor()}y ago';
}

class _SessionTile extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = session.pending && session.title.trim().isEmpty
        ? 'new worktree'
        : (session.title.trim().isNotEmpty
              ? session.title.trim()
              : (session.agent.trim().isNotEmpty ? session.agent : session.id));
    final tile = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        selected: selected,
        selectedTileColor: theme.colorScheme.surfaceContainerHighest,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
            const SizedBox(width: 6),
            Expanded(
              child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        onTap: onTap,
      ),
    );
    // Drag a session onto a pane to open/move it there. Horizontal affinity so
    // a normal vertical drag still scrolls the sidebar; a rightward pull (into
    // the panes) starts the drag.
    return Draggable<SessionDragData>(
      data: SessionDragData(session.id),
      affinity: Axis.horizontal,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _SessionDragFeedback(title: title, status: session.status),
      childWhenDragging: Opacity(opacity: 0.4, child: tile),
      child: tile,
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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        constraints: const BoxConstraints(maxWidth: 220),
        decoration: BoxDecoration(
          color: cs.primaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (status != SessionStatus.idle) ...[
              SessionStatusDot(status: status),
              const SizedBox(width: 6),
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
    final archived = ref.watch(sidebarArchivedProvider) as bool?;
    final showArchived = archived ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          const ConnectionChip(),
          const SizedBox(width: 8),
          if (endpoint != null)
            Expanded(
              child: Text(
                endpoint,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            )
          else
            const Spacer(),
          IconButton(
            tooltip: 'Add repo',
            icon: const Icon(PhosphorIconsLight.folderPlus, size: 18),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () => showFolderBrowser(context),
          ),
          IconButton(
            tooltip: showArchived
                ? 'Show active sessions'
                : 'Show archived sessions',
            icon: Icon(
              showArchived
                  ? PhosphorIconsLight.stackSimple
                  : PhosphorIconsLight.archiveBox,
              size: 18,
            ),
            color: showArchived ? theme.colorScheme.primary : null,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () => ref.read(sidebarArchivedProvider.notifier).state =
                !showArchived,
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
        padding: const EdgeInsets.all(24),
        child: Text(
          'No repos yet.\nUse the + button below\nto add a git repo.',
          textAlign: TextAlign.center,
          style: TextStyle(color: cs.outline),
        ),
      ),
    );
  }
}
