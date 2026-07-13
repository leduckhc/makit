import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../store/models.dart';
import '../../store/store.dart';
import '../../app/theme.dart' show kMakitAccent;
import '../project/folder_browser.dart';
import '../widgets/connection_chip.dart';
import '../widgets/glass.dart';
import '../widgets/searchable_list_sheet.dart';

/// Brand green accent used for running/active glass affordances (shared token).
const _kBrandBlue = kMakitAccent;
const _kAdd = Color(0xFF3FB950); // git additions (green)
const _kDel = Color(0xFFF85149); // git deletions (red)

/// Home screen — organised around **repos**. Each repo card surfaces its
/// branches (worktrees), diff size, open PRs, and the sessions running in each
/// worktree. A new session is a draft until its first message names a branch.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repos = ref.watch(reposProvider).repos;
    final sessions = ref.watch(sessionsProvider);
    final cs = Theme.of(context).colorScheme;
    final topInset = MediaQuery.of(context).padding.top;

    return Scaffold(
      extendBodyBehindAppBar: true,
      extendBody: true,
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: () =>
                ref.read(storeControllerProvider.notifier).refreshRepos(),
            child: repos.isEmpty
                ? _EmptyState(
                    onAdd: () => showFolderBrowser(context),
                    topPadding: topInset + 60,
                  )
                : ListView.builder(
                    padding: EdgeInsets.fromLTRB(12, topInset + 60, 12, 24),
                    itemCount: repos.length,
                    itemBuilder: (context, i) => _RepoCard(
                      repo: repos[i],
                      sessions: sessions.forProject(repos[i].id),
                    ),
                  ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Container(
                height: topInset + 96,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      cs.surface.withValues(alpha: 0.80),
                      cs.surface.withValues(alpha: 0.70),
                      cs.surface.withValues(alpha: 0),
                    ],
                    stops: const [0, 0.5, 1],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'makit',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w600,
                              shadows: [
                                Shadow(color: cs.surface, blurRadius: 6),
                                Shadow(color: cs.surface, blurRadius: 12),
                              ],
                            ),
                      ),
                    ),
                    GlassCircleButton(
                      icon: Icons.create_new_folder_outlined,
                      tooltip: 'Add repo',
                      onTap: () => showFolderBrowser(context),
                    ),
                    const SizedBox(width: 6),
                    GlassCircleButton(
                      icon: Icons.settings_outlined,
                      tooltip: 'Settings',
                      onTap: () => context.go('/settings'),
                    ),
                    const SizedBox(width: 6),
                    const ConnectionChip(circular: true),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd, required this.topPadding});
  final VoidCallback onAdd;
  final double topPadding;

  @override
  Widget build(BuildContext context) {
    // Wrapped in a scroll view so RefreshIndicator still works when empty.
    return ListView(
      padding: EdgeInsets.only(top: topPadding),
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.18),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: GlassSurface(
              borderRadius: 24,
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.hub_outlined, size: 64),
                    const SizedBox(height: 12),
                    const Text(
                      'No repos yet.\nAdd a git repo to get started.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: onAdd,
                      icon: const Icon(Icons.create_new_folder_outlined),
                      label: const Text('Add repo'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Repo card
// ---------------------------------------------------------------------------

class _RepoCard extends ConsumerWidget {
  const _RepoCard({required this.repo, required this.sessions});
  final RepoInfo repo;
  final List<Session> sessions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final drafts = sessions.where((s) => s.pending).toList();
    final byId = {for (final s in sessions) s.id: s};

    // Show worktrees with running sessions or changes first; hide empty
    // non-primary worktrees behind the primary + active ones.
    final worktrees = [...repo.worktrees]
      ..sort((a, b) {
        if (a.isPrimary != b.isPrimary) return a.isPrimary ? -1 : 1;
        final aActive = a.sessionIds.isNotEmpty || a.hasChanges;
        final bActive = b.sessionIds.isNotEmpty || b.hasChanges;
        if (aActive != bActive) return aActive ? -1 : 1;
        return (b.insertions + b.deletions) - (a.insertions + a.deletions);
      });

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassSurface(
        borderRadius: 20,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context, ref, theme),
            _statStrip(context, theme),
            const Divider(height: 1),
            for (final wt in worktrees)
              _WorktreeRow(
                repo: repo,
                worktree: wt,
                sessions: wt.sessionIds
                    .map((id) => byId[id])
                    .whereType<Session>()
                    .toList(),
              ),
            if (drafts.isNotEmpty) _draftsSection(context, drafts),
            _footer(context, ref),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, WidgetRef ref, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 6, 6),
      child: Row(
        children: [
          const Icon(Icons.folder_special_outlined, size: 20),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              repo.name,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          if (repo.currentBranch != null)
            _BranchChip(branch: repo.currentBranch!, subtle: true),
          const Spacer(),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 20),
            tooltip: 'Repo actions',
            onSelected: (value) {
              switch (value) {
                case 'new':
                  _newSession(context, ref);
                case 'attach':
                  _attachPast(context, ref);
                case 'remove':
                  _confirmRemove(context, ref);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'new',
                child: ListTile(
                  leading: Icon(Icons.add),
                  title: Text('New session'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'attach',
                child: ListTile(
                  leading: Icon(Icons.replay),
                  title: Text('Resume session'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'remove',
                child: ListTile(
                  leading: Icon(Icons.delete_outline),
                  title: Text('Remove from makit'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statStrip(BuildContext context, ThemeData theme) {
    final outline = theme.colorScheme.outline;
    final items = <Widget>[];

    if (repo.defaultBranch != null) {
      items.add(_metaText(context, Icons.flag_outlined, repo.defaultBranch!));
    }
    if (repo.totalInsertions > 0 || repo.totalDeletions > 0) {
      items.add(
        _DiffChip(
          insertions: repo.totalInsertions,
          deletions: repo.totalDeletions,
        ),
      );
    }
    final active = repo.activeWorktreeCount;
    if (active > 0) {
      items.add(
        _metaText(context, Icons.account_tree_outlined, '$active active'),
      );
    }
    if (repo.openPrCount > 0) {
      items.add(
        _metaText(
          context,
          Icons.merge_outlined,
          '${repo.openPrCount} PR${repo.openPrCount > 1 ? 's' : ''}',
          color: _kBrandBlue,
        ),
      );
    }
    if (items.isEmpty) {
      items.add(
        Text(
          repo.isGitRepo ? 'clean' : 'not a git repo',
          style: theme.textTheme.bodySmall?.copyWith(color: outline),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Wrap(spacing: 14, runSpacing: 6, children: items),
    );
  }

  Widget _draftsSection(BuildContext context, List<Session> drafts) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
          child: Text(
            'DRAFTS',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.outline,
              letterSpacing: 1,
            ),
          ),
        ),
        ...drafts.map((s) => _SessionTile(session: s)),
      ],
    );
  }

  Widget _footer(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => _newSession(context, ref),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('New session'),
          style: TextButton.styleFrom(foregroundColor: _kBrandBlue),
        ),
      ),
    );
  }

  Widget _metaText(
    BuildContext context,
    IconData icon,
    String text, {
    Color? color,
  }) {
    final c = color ?? Theme.of(context).colorScheme.outline;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: c),
        const SizedBox(width: 4),
        Text(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c),
        ),
      ],
    );
  }

  // ---- actions ------------------------------------------------------------

  Future<void> _newSession(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final store = ref.read(storeControllerProvider.notifier);
    try {
      final agents = await store.fetchAgents();
      final selectable = agents.where((a) => a.available).toList();
      String? chosen;
      if (selectable.length > 1) {
        if (!context.mounted) return;
        chosen = await showModalBottomSheet<String>(
          context: context,
          showDragHandle: true,
          builder: (ctx) => _AgentPickerSheet(agents: selectable),
        );
        if (chosen == null) return;
      }
      final newId = await store.spawnSession(repo.id, agent: chosen);
      if (!context.mounted) return;
      context.go('/session/$newId');
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not start session: $e')),
      );
    }
  }

  Future<void> _confirmRemove(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final store = ref.read(storeControllerProvider.notifier);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${repo.name}?'),
        content: const Text(
          'This removes the repo from makit. Files on disk (and worktrees) are '
          'not touched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await store.removeProject(repo.id);
      messenger.showSnackBar(SnackBar(content: Text('Removed ${repo.name}')));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not remove repo: $e')),
      );
    }
  }

  Future<void> _attachPast(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final store = ref.read(storeControllerProvider.notifier);
    List<PiSessionMeta> metas;
    try {
      metas = await store.listPiSessions(repo.id);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not list past sessions: $e')),
      );
      return;
    }
    if (!context.mounted) return;

    final chosen = await showSearchableListSheet<PiSessionMeta>(
      context: context,
      title: 'Resume session in ${repo.name}',
      items: metas,
      emptyState: const Padding(
        padding: EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Text('No past sessions.', textAlign: TextAlign.center),
      ),
      matches: (m, q) {
        final ql = q.toLowerCase();
        return m.name.toLowerCase().contains(ql) ||
            m.preview.toLowerCase().contains(ql);
      },
      tileBuilder: (ctx, m) => ListTile(
        leading: Icon(
          m.attached ? Icons.bolt : Icons.replay,
          color: m.attached ? Colors.green : null,
        ),
        title: Text(
          m.name.isEmpty ? '(untitled)' : m.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${m.messageCount} msgs · ${_ago(m.lastActivityAt)}'
          '${m.preview.isEmpty ? '' : ' · ${m.preview}'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: m.attached
            ? Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  'live',
                  style: TextStyle(
                    color: Colors.green,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              )
            : null,
        onTap: () => Navigator.of(ctx).pop(m),
      ),
    );
    if (chosen == null || !context.mounted) return;

    try {
      final sid = await store.attachSession(repo.id, chosen.piSessionId);
      if (!context.mounted) return;
      context.go('/session/$sid');
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not attach session: $e')),
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Worktree row + its sessions
// ---------------------------------------------------------------------------

class _WorktreeRow extends StatelessWidget {
  const _WorktreeRow({
    required this.repo,
    required this.worktree,
    required this.sessions,
  });
  final RepoInfo repo;
  final Worktree worktree;
  final List<Session> sessions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final branch = worktree.branch ?? 'detached';
    final isDefault = worktree.branch == repo.defaultBranch;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Row(
            children: [
              Icon(
                Icons.account_tree_outlined,
                size: 15,
                color: worktree.isPrimary
                    ? theme.colorScheme.outline
                    : _kBrandBlue,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  branch,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFeatures: const [],
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isDefault) ...[
                const SizedBox(width: 6),
                _Tag(label: 'default', color: theme.colorScheme.outline),
              ],
              const SizedBox(width: 8),
              if (worktree.hasChanges)
                _DiffChip(
                  insertions: worktree.insertions,
                  deletions: worktree.deletions,
                ),
              if (worktree.pr != null) ...[
                const SizedBox(width: 8),
                _PrPill(pr: worktree.pr!),
              ],
            ],
          ),
        ),
        if (sessions.isEmpty && !worktree.isPrimary)
          Padding(
            padding: const EdgeInsets.fromLTRB(38, 0, 16, 6),
            child: Text(
              worktree.filesChanged > 0
                  ? '${worktree.filesChanged} file(s) changed · no live session'
                  : 'no live session',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
        ...sessions.map((s) => _SessionTile(session: s, indented: true)),
      ],
    );
  }
}

/// Compact "x ago" from an epoch-ms timestamp.
String _ago(int epochMs) {
  if (epochMs <= 0) return 'unknown';
  final d = DateTime.now().difference(
    DateTime.fromMillisecondsSinceEpoch(epochMs),
  );
  if (d.inDays > 0) return '${d.inDays}d ago';
  if (d.inHours > 0) return '${d.inHours}h ago';
  if (d.inMinutes > 0) return '${d.inMinutes}m ago';
  return 'just now';
}

class _SessionTile extends ConsumerWidget {
  const _SessionTile({required this.session, this.indented = false});
  final Session session;
  final bool indented;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return Dismissible(
      key: ValueKey('sess-${session.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        color: cs.errorContainer,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.power_settings_new, color: cs.onErrorContainer),
            const SizedBox(width: 8),
            Text(
              'Quit',
              style: TextStyle(
                color: cs.onErrorContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
      confirmDismiss: (_) => _confirmQuit(context),
      onDismissed: (_) => _quit(context, ref),
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.only(left: indented ? 30 : 16, right: 12),
        onTap: () => context.go('/session/${session.id}'),
        leading: _AgentAvatar(agent: session.agent),
        title: Row(
          children: [
            Expanded(
              child: Text(
                session.pending && session.title.trim().isEmpty
                    ? 'new session'
                    : session.title,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (session.pending)
              const _Tag(label: 'draft', color: Colors.amber)
            else if (session.status != SessionStatus.idle)
              _StatusChip(status: session.status),
          ],
        ),
        subtitle: Text(
          session.pending
              ? 'Send a message to create a branch'
              : session.lastPreview,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Future<bool> _confirmQuit(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Quit session?'),
        content: Text(
          'Stop “${session.title}” and remove it? '
          'The transcript stays on disk and can be re-attached.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('Quit'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _quit(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(storeControllerProvider.notifier).killSession(session.id);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not quit: $e')));
    }
  }
}

// ---------------------------------------------------------------------------
// Small presentational widgets
// ---------------------------------------------------------------------------

/// Agent avatar: shows the agent's logo for known agents, else the initial.
class _AgentAvatar extends StatelessWidget {
  const _AgentAvatar({required this.agent});
  final String agent;

  @override
  Widget build(BuildContext context) {
    final asset = _agentLogos[agent.toLowerCase()];
    if (asset == null) {
      return CircleAvatar(
        radius: 16,
        backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
        child: Text(agent.isEmpty ? '?' : agent.substring(0, 1).toUpperCase()),
      );
    }
    return ClipOval(
      child: SvgPicture.asset(asset, width: 32, height: 32, fit: BoxFit.cover),
    );
  }
}

const _agentLogos = <String, String>{
  'pi': 'assets/agents/pi.svg',
  'codex': 'assets/agents/codex.svg',
  'claude': 'assets/agents/claude.svg',
};

/// Branch name pill with a git branch glyph.
class _BranchChip extends StatelessWidget {
  const _BranchChip({required this.branch, this.subtle = false});
  final String branch;
  final bool subtle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = subtle ? cs.outline : _kBrandBlue;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.commit_outlined, size: 12, color: color),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(
              branch,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// `+N −M` diff chip with additive-green / deletive-red counts.
class _DiffChip extends StatelessWidget {
  const _DiffChip({required this.insertions, required this.deletions});
  final int insertions;
  final int deletions;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (insertions > 0)
          Text(
            '+$insertions',
            style: const TextStyle(
              color: _kAdd,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              fontFamily: 'monospace',
            ),
          ),
        if (insertions > 0 && deletions > 0) const SizedBox(width: 5),
        if (deletions > 0)
          Text(
            '−$deletions',
            style: const TextStyle(
              color: _kDel,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              fontFamily: 'monospace',
            ),
          ),
      ],
    );
  }
}

/// Open-PR pill: `PR #42`, tinted grey for drafts, brand for ready.
class _PrPill extends StatelessWidget {
  const _PrPill({required this.pr});
  final PullRequest pr;

  @override
  Widget build(BuildContext context) {
    final color = pr.isDraft ? Colors.grey : _kBrandBlue;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            pr.isDraft ? Icons.merge_type : Icons.merge_outlined,
            size: 12,
            color: color,
          ),
          const SizedBox(width: 3),
          Text(
            'PR #${pr.number}',
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Generic little tag chip (default / draft).
class _Tag extends StatelessWidget {
  const _Tag({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final SessionStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      SessionStatus.running => ('running', _kBrandBlue),
      SessionStatus.awaitingInput => ('you', Colors.orange),
      SessionStatus.awaitingApproval => ('approve', Colors.deepOrange),
      SessionStatus.error => ('error', Colors.red),
      SessionStatus.exited => ('exited', Colors.grey),
      SessionStatus.idle => ('idle', Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Bottom sheet that lets the user pick which agent to spawn. Pops the chosen
/// agent id, or null if dismissed.
class _AgentPickerSheet extends StatelessWidget {
  const _AgentPickerSheet({required this.agents});

  final List<AgentDescriptor> agents;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Text(
              'Choose an agent',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          for (final a in agents)
            ListTile(
              leading: const Icon(Icons.smart_toy_outlined),
              title: Text(a.label),
              subtitle: Text(a.transport.toUpperCase()),
              onTap: () => Navigator.pop(context, a.id),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
