import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../../store/store.dart';
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
      padding: const EdgeInsets.only(bottom: kSpace10),
      child: DecoratedBox(
        // Solid card, not glass: the accent bars are this card's signal, and a
        // translucent surface let scrolling content bleed through and muddy
        // them.
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(kRadius12),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(kRadius12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(context, ref, theme),
              if (_expanded) ...[
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
    final cs = theme.colorScheme;
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
                  color: cs.outline,
                ),
              ),
              const SizedBox(width: kSpace6),
              Icon(PhosphorIconsLight.folder, size: 17, color: cs.outline),
              const SizedBox(width: kSpace8),
              Flexible(
                child: Text(
                  repo.name,
                  // Bold carries the hierarchy, as in the sidebar — a repo is a
                  // name, so no all-caps tracking, and it sits one step above
                  // the branch rather than being a page title.
                  style: theme.textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Spacer(),
              // The header carries only what the rows can't: the repo's default
              // branch and its open-PR count. Per-worktree state lives on the
              // rows, so the old stat strip's "N active" was restating the bars
              // right below it.
              if (repo.defaultBranch != null) ...[
                _metaText(
                  context,
                  PhosphorIconsLight.flag,
                  repo.defaultBranch!,
                ),
                const SizedBox(width: kSpace8),
              ],
              if (repo.openPrCount > 0) ...[
                _prCountPill(context, repo.openPrCount),
                const SizedBox(width: kSpace4),
              ],
              PopupMenuButton<String>(
                icon: Icon(
                  PhosphorIconsRegular.dotsThree,
                  size: 18,
                  color: cs.outline,
                ),
                tooltip: 'Repo actions',
                popUpAnimationStyle: AnimationStyle.noAnimation,
                onSelected: (value) {
                  switch (value) {
                    case 'new':
                      startSessionFlow(context, ref, repo);
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
                    // "New worktree" is not repeated here — the card footer
                    // carries it, always visible and one tap away.
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

  /// Open-PR count as a pill, so the header shows repo-level state at a glance
  /// without a second row. Uses the pull-request symbol, not `gitMerge`, which
  /// means "merged" everywhere else (see [prStateStyle]).
  Widget _prCountPill(BuildContext context, int count) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      key: const Key('openPrCount'),
      padding: const EdgeInsets.symmetric(
        horizontal: kSpace8,
        vertical: kSpace2,
      ),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(kRadius8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            PhosphorIconsLight.gitPullRequest,
            size: kPillIconSize,
            color: cs.primary,
          ),
          const SizedBox(width: 3),
          Text(
            '$count',
            style: Theme.of(context).textTheme.labelXs?.copyWith(
              color: cs.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _draftsSection(BuildContext context, List<Session> drafts) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, kSpace8, 16, kSpace2),
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

  /// Card-level action: add a worktree to this repo.
  ///
  /// Not "New session" — every worktree row carries its own `+` for that, so a
  /// card-level session button could only mean "on some branch I haven't named
  /// yet", which is really just creating a worktree. Starting a session on a
  /// brand-new branch or a PR still lives in the header menu's "New session".
  Widget _footer(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      // Hairline only here: it closes the card and separates the action from the
      // last worktree. Between rows the accent bars already do the dividing.
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: InkWell(
        onTap: () => _newWorktree(context, ref),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: kSpace12,
            vertical: kSpace10,
          ),
          child: Row(
            children: [
              Icon(PhosphorIconsLight.plus, size: 15, color: cs.primary),
              const SizedBox(width: kSpace6),
              Text(
                'New worktree',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: cs.primary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
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
