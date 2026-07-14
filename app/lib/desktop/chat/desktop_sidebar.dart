import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../store/models.dart';
import '../../store/store.dart';
import '../../store/connection.dart';
import '../../ui/home/repo_chips.dart';
import '../../ui/widgets/connection_chip.dart';
import 'connection_endpoint.dart';
import 'new_session_dialog.dart';
import 'selected_session.dart';
import 'sidebar_layout.dart';

/// The left pane of the desktop two-pane chat. Mirrors the mobile repo-centric
/// home (SPEC-11): repos → worktrees (branch, diff stats, open PR) → the
/// sessions running in each worktree, plus a DRAFTS section for sessions that
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
                        onSelect: (id) =>
                            ref.read(selectedSessionProvider.notifier).state =
                                id,
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
    return SizedBox(
      height: kTitleBarStripHeight,
      width: double.infinity,
      child: Stack(
        children: [
          const Positioned.fill(
            child: DragToMoveArea(child: SizedBox.expand()),
          ),
          Positioned(
            left: kTrafficLightInset,
            top: 2,
            child: IconButton(
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              tooltip: 'Hide sidebar',
              icon: const Icon(Icons.view_sidebar_outlined),
              onPressed: () =>
                  ref.read(sidebarCollapsedProvider.notifier).state = true,
            ),
          ),
        ],
      ),
    );
  }
}

/// One repo section: header row (name + current branch + stats), then its
/// worktrees with their sessions, then drafts.
class _RepoGroup extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final drafts = sessions.where((s) => s.pending).toList();
    final byId = {for (final s in sessions) s.id: s};
    final worktrees = sortWorktreesForDisplay(repo.worktrees);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 2),
          child: Row(
            children: [
              Icon(
                Icons.folder_special_outlined,
                size: 16,
                color: theme.colorScheme.outline,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  repo.name,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                    letterSpacing: 0.6,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'New session in ${repo.name}',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.add, size: 16),
                onPressed: () =>
                    showNewSessionDialog(context, ref, projectId: repo.id),
              ),
            ],
          ),
        ),
        if (repo.openPrCount > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              '${repo.openPrCount} open PR${repo.openPrCount > 1 ? 's' : ''}',
              style: theme.textTheme.bodySmall?.copyWith(color: kRepoAccent),
            ),
          ),
        for (final wt in worktrees)
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
        if (drafts.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'DRAFTS',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
                letterSpacing: 1,
              ),
            ),
          ),
          for (final s in drafts)
            _SessionTile(
              session: s,
              selected: s.id == selectedId,
              onTap: () => onSelect(s.id),
            ),
        ],
      ],
    );
  }
}

/// A worktree line (branch + diff, then an optional PR line) with its sessions
/// nested below. Clicking the branch row collapses/expands its sessions.
class _WorktreeGroup extends StatefulWidget {
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
  State<_WorktreeGroup> createState() => _WorktreeGroupState();
}

class _WorktreeGroupState extends State<_WorktreeGroup> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repo = widget.repo;
    final worktree = widget.worktree;
    final sessions = widget.sessions;
    final branch = worktree.branch ?? 'detached';
    final isDefault = worktree.branch == repo.defaultBranch;
    final isCurrent =
        worktree.branch != null && worktree.branch == repo.currentBranch;

    // Only surface worktrees with a live session (strict).
    if (sessions.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
            child: Row(
              children: [
                Icon(
                  _expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 14,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.account_tree_outlined,
                  size: 13,
                  color: worktree.isPrimary
                      ? theme.colorScheme.outline
                      : kRepoAccent,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    branch,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (isCurrent) ...[
                  const SizedBox(width: 5),
                  const Icon(Icons.star, size: 13, color: Colors.amber),
                ],
                if (isDefault) ...[
                  const SizedBox(width: 6),
                  TagChip(label: 'default', color: theme.colorScheme.outline),
                ],
                const SizedBox(width: 8),
                if (worktree.hasChanges)
                  DiffChip(
                    insertions: worktree.insertions,
                    deletions: worktree.deletions,
                  ),
              ],
            ),
          ),
        ),
        if (worktree.pr != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(38, 0, 16, 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: PrPill(pr: worktree.pr!),
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
        ? 'new session'
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
          if (session.pending)
            const TagChip(label: 'draft', color: Colors.amber)
          else if (session.status != SessionStatus.idle)
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
              icon: const Icon(Icons.settings_outlined),
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
