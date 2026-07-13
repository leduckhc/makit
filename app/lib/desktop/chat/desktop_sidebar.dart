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

/// Height of the sidebar's top drag strip. Sized to clear the macOS
/// traffic-light buttons that overlay the top-left corner once the OS titlebar
/// is hidden (matches the standard macOS titlebar height).
const double _kTitleBarStripHeight = 28;

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

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    // The OS titlebar is hidden (TitleBarStyle.hidden), so this strip is the
    // window's drag handle. Its height clears the macOS traffic-light buttons
    // that overlay the top-left corner.
    return const DragToMoveArea(
      child: SizedBox(height: _kTitleBarStripHeight, width: double.infinity),
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
              Flexible(
                child: Text(
                  repo.name.toUpperCase(),
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                    letterSpacing: 0.6,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Spacer(),
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

/// A worktree line (branch + diff + PR) with its sessions nested below.
class _WorktreeGroup extends StatelessWidget {
  const _WorktreeGroup({
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final branch = worktree.branch ?? 'detached';
    final isDefault = worktree.branch == repo.defaultBranch;
    final isCurrent =
        worktree.branch != null && worktree.branch == repo.currentBranch;

    // Only surface worktrees with a live session (strict).
    if (sessions.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
          child: Row(
            children: [
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
              if (worktree.pr != null) ...[
                const SizedBox(width: 6),
                Flexible(child: PrPill(pr: worktree.pr!)),
              ],
            ],
          ),
        ),
        for (final s in sessions)
          _SessionTile(
            session: s,
            selected: s.id == selectedId,
            indented: true,
            onTap: () => onSelect(s.id),
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
        : (session.title.trim().isNotEmpty ? session.title.trim() : session.id);
    return ListTile(
      dense: true,
      selected: selected,
      selectedTileColor: theme.colorScheme.surfaceContainerHighest,
      contentPadding: EdgeInsets.only(left: indented ? 28 : 16, right: 12),
      leading: AgentAvatar(agent: session.agent, size: 26),
      title: Row(
        children: [
          Expanded(
            child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (session.pending)
            const TagChip(label: 'draft', color: Colors.amber)
          else if (session.status != SessionStatus.idle)
            SessionStatusChip(status: session.status),
        ],
      ),
      subtitle: Text(
        session.pending
            ? 'Send a message to create a branch'
            : (session.lastPreview.isEmpty
                  ? session.agent
                  : session.lastPreview),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.outline,
        ),
      ),
      onTap: onTap,
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
