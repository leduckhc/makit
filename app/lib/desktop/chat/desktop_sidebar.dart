import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../store/models.dart';
import '../../store/store.dart';
import '../../store/connection.dart';
import '../../ui/home/repo_chips.dart';
import '../../ui/widgets/connection_chip.dart';
import 'connection_endpoint.dart';
import 'title_bar_strip.dart';
import 'new_session_dialog.dart';
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

    return Column(
      children: [
        const _Header(),
        Expanded(
          child: repos.isEmpty
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
    return const TitleBarStrip(leading: SidebarToggleButton(collapse: true));
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repo = widget.repo;
    final sessions = widget.sessions;
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
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 2),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => setState(() => _expanded = !_expanded),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Icon(
                          _expanded
                              ? Symbols.keyboard_arrow_down
                              : Symbols.keyboard_arrow_right,
                          size: 16,
                          weight: 200,
                          color: theme.colorScheme.outline,
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          Symbols.folder_special,
                          size: 16,
                          weight: 200,
                          color: theme.colorScheme.outline,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            repo.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              letterSpacing: 0.6,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              _RepoMenuButton(repo: repo),
              IconButton(
                tooltip: 'New worktree',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Symbols.add, size: 16, weight: 200),
                onPressed: () =>
                    showNewSessionDialog(context, ref, projectId: repo.id),
              ),
            ],
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
              padding: const EdgeInsets.fromLTRB(38, 2, 16, 4),
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

/// The repo header's overflow menu (the triple-dots left of +). Hosts repo-
/// scoped actions: hide the repo (untrack it) and open the richer
/// "New worktree from…" dialog. More items land here later.
class _RepoMenuButton extends ConsumerWidget {
  const _RepoMenuButton({required this.repo});

  final RepoInfo repo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      tooltip: 'Repo actions',
      icon: const Icon(Symbols.more_horiz, size: 16, weight: 200),
      onSelected: (value) {
        switch (value) {
          case 'hide':
            _hideRepo(context, ref);
          case 'new-worktree':
            showNewSessionDialog(context, ref, projectId: repo.id);
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem(value: 'hide', child: Text('Hide the repo')),
        PopupMenuItem(value: 'new-worktree', child: Text('New worktree from…')),
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
          child: InkWell(
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
            child: Container(
              color: worktreeSelected
                  ? theme.colorScheme.surfaceContainerHighest
                  : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
                    child: Row(
                      children: [
                        const SizedBox(width: 4),
                        // Open PR → the merge symbol; otherwise the plain
                        // worktree/branch icon that predated the PR-centric
                        // redesign (still used by the draft-worktree tile and
                        // any non-open PR).
                        if (worktree.pr?.state.toUpperCase() == 'OPEN')
                          const Icon(
                            Symbols.call_merge,
                            size: 24,
                            weight: 200,
                            color: kRepoAccent,
                          )
                        else
                          Icon(
                            Symbols.fork_right,
                            size: 24,
                            weight: 200,
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
                                  Symbols.star,
                                  size: 13,
                                  weight: 200,
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
                    padding: const EdgeInsets.fromLTRB(52, 0, 16, 4),
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
    return PopupMenuButton<String>(
      tooltip: 'Worktree actions',
      icon: const Icon(Symbols.more_vert, size: 16, weight: 200),
      onOpened: onMenuOpened,
      onCanceled: () => onSelected(''),
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
        PopupMenuItem(
          value: 'delete',
          enabled: !isPrimary,
          child: Tooltip(
            message: isPrimary ? "Can't delete the primary worktree" : '',
            child: const Text('Delete worktree'),
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
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? theme.colorScheme.surfaceContainerHighest : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
              child: Row(
                children: [
                  const SizedBox(width: 4),
                  Icon(
                    Symbols.fork_right,
                    size: 24,
                    weight: 200,
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
              padding: const EdgeInsets.fromLTRB(38, 0, 16, 4),
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
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      selected: selected,
      selectedTileColor: theme.colorScheme.surfaceContainerHighest,
      contentPadding: EdgeInsets.only(left: indented ? 38 : 16, right: 12),
      title: Row(
        children: [
          Expanded(
            child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (session.status != SessionStatus.idle)
            _StatusDot(status: session.status),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// A tiny status indicator dot. Active states (running / awaiting) pulse; the
/// rest render as a solid dot. Replaces the old text status chip on the compact
/// single-line session tiles.
class _StatusDot extends StatefulWidget {
  const _StatusDot({required this.status});
  final SessionStatus status;

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot> with TickerProviderStateMixin {
  AnimationController? _controller;

  bool get _pulses =>
      widget.status == SessionStatus.running ||
      widget.status == SessionStatus.awaitingInput ||
      widget.status == SessionStatus.awaitingApproval;

  @override
  void initState() {
    super.initState();
    _syncController();
  }

  @override
  void didUpdateWidget(_StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sessions transition status in place (running → exited, idle → running…)
    // and this State object is reused, so the controller must track the
    // current status — not the one we mounted with.
    if (oldWidget.status != widget.status) _syncController();
  }

  /// Only active states animate — solid states must not leave a repeating
  /// controller running (it would also make pumpAndSettle hang in tests).
  void _syncController() {
    if (_pulses && _controller == null) {
      _controller = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 900),
      )..repeat(reverse: true);
    } else if (!_pulses && _controller != null) {
      _controller!.dispose();
      _controller = null;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// Human-readable status, used for the tooltip + screen-reader semantics so
  /// the dot is not a color-only signal.
  String get _label => switch (widget.status) {
    SessionStatus.running => 'running',
    SessionStatus.awaitingInput => 'awaiting input',
    SessionStatus.awaitingApproval => 'awaiting approval',
    SessionStatus.error => 'error',
    SessionStatus.exited => 'exited',
    SessionStatus.idle => 'idle',
  };

  @override
  Widget build(BuildContext context) {
    final color = switch (widget.status) {
      SessionStatus.running => kRepoAccent,
      SessionStatus.awaitingInput => Colors.orange,
      SessionStatus.awaitingApproval => Colors.deepOrange,
      SessionStatus.error => Colors.red,
      SessionStatus.exited => Colors.grey,
      SessionStatus.idle => Colors.grey,
    };
    Widget dot = Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    final controller = _controller;
    if (controller != null) {
      dot = FadeTransition(
        opacity: Tween<double>(begin: 0.3, end: 1).animate(controller),
        child: dot,
      );
    }
    return Tooltip(
      message: _label,
      child: Semantics(label: 'status: $_label', child: dot),
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
          if (onOpenSettings != null)
            IconButton(
              tooltip: 'Settings & Server',
              icon: const Icon(Symbols.settings, weight: 200),
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
          'No repos yet.\nUse + to start a session\nin a git repo.',
          textAlign: TextAlign.center,
          style: TextStyle(color: cs.outline),
        ),
      ),
    );
  }
}
