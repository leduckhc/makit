import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../../store/store.dart';
import '../widgets/glass.dart';
import '../widgets/searchable_list_sheet.dart';
import 'new_session_sheet.dart';
import 'repo_chips.dart';
import 'session_tile.dart';
import 'worktree_row.dart';

/// A repo card on the home screen: header, stat strip, its worktree rows,
/// drafts, and a "new session" footer (SPEC-19, moved from home_screen).
class RepoCard extends ConsumerWidget {
  const RepoCard({super.key, required this.repo, required this.sessions});
  final RepoInfo repo;
  final List<Session> sessions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final drafts = sessions.where((s) => s.pending).toList();
    final byId = {for (final s in sessions) s.id: s};

    // Show worktrees with running sessions or changes first; hide empty
    // non-primary worktrees behind the primary + active ones.
    final worktrees = sortWorktreesForDisplay(repo.worktrees);

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
              WorktreeRow(
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
          const Icon(PhosphorIconsLight.folderStar, size: 20),
          const SizedBox(width: kSpace10),
          Flexible(
            child: Text(
              repo.name,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Spacer(),
          PopupMenuButton<String>(
            icon: const Icon(PhosphorIconsLight.dotsThreeVertical, size: 20),
            tooltip: 'Repo actions',
            popUpAnimationStyle: AnimationStyle.noAnimation,
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
            itemBuilder: (context) {
              final cs = Theme.of(context).colorScheme;
              return [
                const PopupMenuItem(
                  value: 'new',
                  child: ListTile(
                    leading: Icon(PhosphorIconsLight.plus),
                    title: Text('New session'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuItem(
                  value: 'attach',
                  child: ListTile(
                    leading: Icon(PhosphorIconsLight.arrowCounterClockwise),
                    title: Text('Resume session'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'remove',
                  child: ListTile(
                    leading: Icon(PhosphorIconsLight.trash, color: cs.error),
                    title: Text(
                      'Remove from makit',
                      style: TextStyle(color: cs.error),
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ];
            },
          ),
        ],
      ),
    );
  }

  Widget _statStrip(BuildContext context, ThemeData theme) {
    final outline = theme.colorScheme.outline;
    final items = <Widget>[];

    if (repo.defaultBranch != null) {
      items.add(
        _metaText(context, PhosphorIconsLight.flag, repo.defaultBranch!),
      );
    }
    final active = repo.activeWorktreeCount;
    if (active > 0) {
      items.add(
        _metaText(context, PhosphorIconsLight.treeStructure, '$active active'),
      );
    }
    if (repo.openPrCount > 0) {
      items.add(
        _metaText(
          context,
          PhosphorIconsLight.gitMerge,
          '${repo.openPrCount} PR${repo.openPrCount > 1 ? 's' : ''}',
          color: theme.colorScheme.primary,
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
        ...drafts.map((s) => SessionTile(session: s)),
      ],
    );
  }

  Widget _footer(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
      child: Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: () => _newSession(context, ref),
          icon: const Icon(PhosphorIconsLight.plus, size: 18),
          label: const Text('New session'),
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.primary,
          ),
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
        const SizedBox(width: kSpace4),
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
    final branches = branchOptionsForRepo(repo);
    final worktrees = sortWorktreesForDisplay(repo.worktrees);
    try {
      final agents = await store.fetchAgents();
      final selectable = agents.where((a) => a.available).toList();
      // Open PRs power the "From PR" worktree source; best-effort (an empty or
      // failed lookup just hides that option). Bounded so a slow `gh` can't
      // stall opening the sheet.
      List<OpenPr> openPrs = const [];
      try {
        openPrs = await store
            .listOpenPrs(repo.id)
            .timeout(
              const Duration(seconds: 2),
              onTimeout: () => const <OpenPr>[],
            );
      } catch (_) {
        openPrs = const [];
      }

      String? chosenAgent;
      String? chosenBranch = branches.isEmpty ? null : branches.first;
      String? worktreePath;
      List<ConfigOptionPick>? picks;

      // Show the sheet whenever there's something to configure: more than one
      // harness/branch/worktree, any open PRs, or a harness with config options.
      final hasConfig = selectable.any((a) => a.configOptions.isNotEmpty);
      final worthPrompting =
          selectable.length > 1 ||
          branches.length > 1 ||
          worktrees.length > 1 ||
          openPrs.isNotEmpty ||
          hasConfig;
      if (worthPrompting) {
        if (!context.mounted) return;
        final choice = await showModalBottomSheet<NewSessionChoice>(
          context: context,
          showDragHandle: true,
          isScrollControlled: true,
          builder: (ctx) => NewSessionSheet(
            agents: selectable,
            branches: branches,
            worktrees: worktrees,
            openPrs: openPrs,
            initialBranch: chosenBranch,
          ),
        );
        if (choice == null) return;
        chosenAgent = choice.agent;
        switch (choice.source) {
          case WorktreeSource.existing:
            worktreePath = choice.worktreePath;
          case WorktreeSource.newBranch:
            chosenBranch = choice.baseBranch ?? chosenBranch;
          case WorktreeSource.fromPr:
            if (choice.prNumber != null) {
              final wt = await store.createWorktreeFromPr(
                repo.id,
                choice.prNumber!,
              );
              worktreePath = wt.path;
            }
        }
        // Landing on an existing/PR worktree overrides the base-branch fork.
        if (worktreePath != null) chosenBranch = null;
        picks = choice.configOptions.isEmpty ? null : choice.configOptions;
      }
      final newId = await store.spawnSession(
        repo.id,
        agent: chosenAgent,
        baseBranch: chosenBranch,
        worktreePath: worktreePath,
        configOptions: picks,
      );
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
          m.attached
              ? PhosphorIconsLight.lightning
              : PhosphorIconsLight.arrowCounterClockwise,
          color: m.attached ? Theme.of(context).colorScheme.primary : null,
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
                padding: const EdgeInsets.symmetric(
                  horizontal: kSpace8,
                  vertical: kSpace2,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(kRadius10),
                ),
                child: Text(
                  'live',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
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
