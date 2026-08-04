import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../../store/store.dart';
import '../widgets/glass.dart';
import '../widgets/menu_item.dart';
import '../widgets/searchable_list_sheet.dart';
import '../widgets/sheet_header.dart';
import 'repo_chips.dart';
import 'start_session.dart';
import 'session_tile.dart';
import 'worktree_row.dart';

/// A repo card on the home screen: header, stat strip, its worktree rows,
/// drafts, and a "new session" footer (SPEC-19, moved from home_screen).
///
/// Tapping the header collapses everything below it, and past [_maxCollapsed]
/// worktrees the tail hides behind a "Show N more" toggle — both mirroring the
/// desktop sidebar's repo group, so many repos or many branches stay navigable
/// by thumb.
class RepoCard extends ConsumerStatefulWidget {
  const RepoCard({super.key, required this.repo, required this.sessions});
  final RepoInfo repo;
  final List<Session> sessions;

  @override
  ConsumerState<RepoCard> createState() => _RepoCardState();
}

class _RepoCardState extends ConsumerState<RepoCard> {
  /// How many worktrees show before the "Show N more" toggle kicks in (the
  /// desktop sidebar's cap).
  static const int _maxCollapsed = 5;

  /// Whether the card's contents are shown. Collapsed, the header and stat strip
  /// remain — "New session" is still reachable from the header menu.
  bool _expanded = true;

  /// Whether the worktrees past [_maxCollapsed] are shown.
  bool _showAll = false;

  RepoInfo get repo => widget.repo;
  List<Session> get sessions => widget.sessions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Exited sessions are hidden from the card — but only the truly dead ones.
    // A cold, RESUMABLE session (e.g. every session after a server restart,
    // before re-attach) stays visible so it remains discoverable and can be
    // reopened; it auto-attaches on subscribe. Mirrors the desktop sidebar.
    final live = sessions
        .where((s) => s.status != SessionStatus.exited || s.resumable)
        .toList();
    final drafts = live.where((s) => s.pending).toList();
    final byId = {for (final s in live) s.id: s};

    // Worktrees with running sessions or changes first; the quiet tail sinks to
    // the bottom, which is also what the "Show N more" cut hides.
    final worktrees = sortWorktreesForDisplay(repo.worktrees);
    final showMore = worktrees.length > _maxCollapsed;
    final visible = (_showAll || !showMore)
        ? worktrees
        : worktrees.take(_maxCollapsed).toList();

    return Padding(
      padding: const EdgeInsets.only(bottom: kSpace8),
      child: GlassSurface(
        borderRadius: 16,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context, ref, theme),
            _statStrip(context, theme),
            if (_expanded) ...[
              const Divider(height: 1),
              for (final wt in visible)
                WorktreeRow(
                  key: ValueKey(wt.path),
                  repo: repo,
                  worktree: wt,
                  sessions: wt.sessionIds
                      .map((id) => byId[id])
                      .whereType<Session>()
                      .toList(),
                ),
              if (showMore) _showMoreToggle(context, worktrees.length),
              if (drafts.isNotEmpty) _draftsSection(context, drafts),
              _footer(context, ref),
            ],
          ],
        ),
      ),
    );
  }

  /// The "Show N more" / "Show less" toggle for the worktree tail.
  Widget _showMoreToggle(BuildContext context, int total) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 16, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: () => setState(() => _showAll = !_showAll),
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            foregroundColor: Theme.of(context).colorScheme.primary,
          ),
          child: Text(
            _showAll ? 'Show less' : 'Show ${total - _maxCollapsed} more',
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, WidgetRef ref, ThemeData theme) {
    return InkWell(
      // Whole header toggles disclosure. The overflow menu below sits on top of
      // it and swallows its own taps, so the two never fight.
      onTap: () => setState(() => _expanded = !_expanded),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kTouchRow),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
          child: Row(
            children: [
              AnimatedRotation(
                turns: _expanded ? 0 : -0.25,
                duration: const Duration(milliseconds: 120),
                child: Icon(
                  PhosphorIconsLight.caretDown,
                  size: 14,
                  color: theme.colorScheme.outline,
                ),
              ),
              const SizedBox(width: kSpace6),
              Icon(
                PhosphorIconsLight.folder,
                size: 17,
                color: theme.colorScheme.outline,
              ),
              const SizedBox(width: kSpace8),
              Flexible(
                child: Text(
                  repo.name,
                  // Bold carries the hierarchy, as in the sidebar — a repo is a
                  // name, so no all-caps tracking, and it sits one step above
                  // the branch rather than being a page title.
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Spacer(),
              PopupMenuButton<String>(
                icon: Icon(
                  PhosphorIconsRegular.dotsThree,
                  size: 18,
                  color: theme.colorScheme.onSurface,
                ),
                tooltip: 'Repo actions',
                popUpAnimationStyle: AnimationStyle.noAnimation,
                onSelected: (value) {
                  switch (value) {
                    case 'new':
                      startSessionFlow(context, ref, repo);
                    case 'worktree':
                      _newWorktree(context, ref);
                    case 'attach':
                      _attachPast(context, ref);
                    case 'remove':
                      _confirmRemove(context, ref);
                  }
                },
                itemBuilder: (context) {
                  final cs = Theme.of(context).colorScheme;
                  return [
                    themedMenuItem(
                      value: 'new',
                      icon: PhosphorIconsLight.plus,
                      label: 'New session',
                    ),
                    themedMenuItem(
                      value: 'worktree',
                      icon: PhosphorIconsLight.gitBranch,
                      label: 'New worktree',
                    ),
                    themedMenuItem(
                      value: 'attach',
                      icon: PhosphorIconsLight.arrowCounterClockwise,
                      label: 'Resume session',
                    ),
                    const PopupMenuDivider(),
                    themedMenuItem(
                      value: 'remove',
                      icon: PhosphorIconsLight.trash,
                      label: 'Remove from makit',
                      color: cs.error,
                    ),
                  ];
                },
              ),
            ],
          ),
        ),
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
        _metaText(context, PhosphorIconsLight.gitBranch, '$active active'),
      );
    }
    if (repo.openPrCount > 0) {
      items.add(
        _metaText(
          context,
          // Open PRs, so the pull-request symbol — not `gitMerge`, which now
          // means "merged" everywhere else (see [prStateStyle]).
          PhosphorIconsLight.gitPullRequest,
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
      padding: const EdgeInsets.fromLTRB(12 + 14 + kSpace6, 0, 16, kSpace8),
      child: Wrap(spacing: kSpace12, runSpacing: kSpace4, children: items),
    );
  }

  Widget _draftsSection(BuildContext context, List<Session> drafts) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, kSpace6, 16, 0),
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
      padding: const EdgeInsets.fromLTRB(8, 0, 8, kSpace4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => startSessionFlow(context, ref, repo),
          icon: const Icon(PhosphorIconsLight.plus, size: 16),
          label: const Text('New session'),
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
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

  /// Create a worktree up front, without starting a session in it — the phone's
  /// version of the sidebar's "+ New worktree". The user picks the fork point;
  /// the branch name is left to the server (as desktop's default does), so the
  /// flow is one tap per decision.
  Future<void> _newWorktree(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final store = ref.read(storeControllerProvider.notifier);
    final branches = branchOptionsForRepo(repo);
    if (branches.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No branches to fork from')),
      );
      return;
    }
    final base = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetHeader(title: 'New worktree from…'),
              for (final b in branches)
                ListTile(
                  leading: const Icon(PhosphorIconsLight.gitBranch),
                  title: Text(b),
                  onTap: () => Navigator.pop(sheetContext, b),
                ),
            ],
          ),
        ),
      ),
    );
    if (base == null) return;
    try {
      final wt = await store.createWorktree(repo.id, baseBranch: base);
      messenger.showSnackBar(
        SnackBar(content: Text('Created ${wt.branch ?? wt.path}')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not create worktree: $e')),
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
