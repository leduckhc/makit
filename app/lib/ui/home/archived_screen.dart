import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../../store/store.dart';
import '../../status/status_event.dart';
import '../../status/status_providers.dart';
import 'repo_chips.dart';

/// The archived-sessions screen (SPEC-29) — the mobile counterpart of the
/// desktop sidebar's Archived view. Archived sessions are not part of the
/// active `sessions.snapshot`, so the list is fetched on demand and grouped by
/// repo; each row restores back to the active list.
class ArchivedScreen extends ConsumerStatefulWidget {
  const ArchivedScreen({super.key});

  @override
  ConsumerState<ArchivedScreen> createState() => _ArchivedScreenState();
}

class _ArchivedScreenState extends ConsumerState<ArchivedScreen> {
  late Future<List<Session>> _future = _load();

  Future<List<Session>> _load() {
    final f = ref.read(storeControllerProvider.notifier).listArchivedSessions();
    // The FutureBuilder below renders any failure. `ignore()` only registers a
    // no-op error listener so a failure landing before the rebuild resubscribes
    // isn't also reported as an unhandled async error; other listeners (the
    // FutureBuilder) still receive it.
    f.ignore();
    return f;
  }

  /// The active session ids the last snapshot carried. Archiving or restoring
  /// elsewhere adds/removes an id, which is our cue to reload; routine
  /// activity/status churn must not.
  /// Seeded in [initState] rather than left null: the listener only fires on a
  /// *change*, so an unseeded baseline swallowed the first one — archive a
  /// session on the home screen with this screen in the stack and the list
  /// stayed stale until a manual pull-to-refresh. Seeding it *empty* is not
  /// enough either: the next snapshot would then always look like a change and
  /// reload for nothing, so it starts from what the store already holds.
  late Set<String> _lastActiveIds;

  @override
  void initState() {
    super.initState();
    _lastActiveIds = {
      for (final s in ref.read(sessionsProvider).sessions) s.id,
    };
  }

  void _refresh() {
    if (!mounted) return;
    // Block body, not an arrow: `setState(() => _future = ...)` returns the
    // assigned Future, which setState rejects.
    setState(() {
      _future = _load();
    });
  }

  Future<void> _restore(Session s) async {
    // Resolved before the first await: `ref` throws once its widget is
    // unmounted, and the record must survive the thing that reported to it.
    final status = ref.status;
    try {
      await ref.read(storeControllerProvider.notifier).unarchiveSession(s.id);
      // The record outlives the screen: submit first, then touch UI state only
      // if this widget is still around to have any.
      status.success(
        'Restored "${s.title}"',
        source: StatusSources.session,
        sessionId: s.id,
      );
      if (!mounted) return;
      _refresh();
    } catch (e) {
      status.failure(
        'Could not restore session',
        error: e,
        source: StatusSources.session,
        sessionId: s.id,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watched here rather than inside _grouped: every dependency this screen
    // rebuilds on is then visible in one place.
    final repos = ref.watch(reposProvider);
    // Live-sync with archive/restore happening elsewhere (e.g. a swipe on the
    // home screen) — see [_lastActiveIds].
    ref.listen<SessionsState>(sessionsProvider, (_, next) {
      final ids = {for (final s in next.sessions) s.id};
      final prev = _lastActiveIds;
      if (ids.length != prev.length || !ids.containsAll(prev)) {
        _refresh();
      }
      _lastActiveIds = ids;
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Archived'),
        leading: IconButton(
          icon: const Icon(PhosphorIconsLight.arrowLeft),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: FutureBuilder<List<Session>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting &&
              !snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) return _error(context);
          final sessions = snap.data ?? const <Session>[];
          if (sessions.isEmpty) return _empty(context);
          return RefreshIndicator(
            onRefresh: () async {
              _refresh();
              await _future.catchError((_) => const <Session>[]);
            },
            child: _grouped(context, sessions, repos),
          );
        },
      ),
    );
  }

  Widget _empty(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(kSpace32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            PhosphorIconsLight.archiveBox,
            size: 48,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: kSpace12),
          Text(
            'No archived sessions.',
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
        ],
      ),
    ),
  );

  Widget _error(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(kSpace24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(PhosphorIconsLight.warningCircle, size: 28, color: cs.error),
            const SizedBox(height: kSpace8),
            Text(
              "Couldn't load archived sessions.",
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: kSpace10),
            TextButton(onPressed: _refresh, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }

  /// Grouped by repo — the one dimension that matters on a phone. The server
  /// already returns newest-first, so first-seen group order reads correctly.
  Widget _grouped(
    BuildContext context,
    List<Session> sessions,
    ReposState repos,
  ) {
    final order = <String>[];
    final byRepo = <String, List<Session>>{};
    for (final s in sessions) {
      byRepo
          .putIfAbsent(s.projectId, () {
            order.add(s.projectId);
            return [];
          })
          .add(s);
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: kSpace24),
      itemCount: order.length,
      itemBuilder: (context, i) {
        final pid = order[i];
        final items = byRepo[pid]!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _GroupHeader(
              title: repos.byId(pid)?.name ?? pid,
              count: items.length,
            ),
            for (final s in items)
              _ArchivedRow(session: s, onRestore: () => _restore(s)),
          ],
        );
      },
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.title, required this.count});
  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, kSpace16, 16, kSpace4),
      child: Row(
        children: [
          Flexible(
            child: Text(
              title.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
          ),
          const SizedBox(width: kSpace8),
          Text(
            '$count',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}

class _ArchivedRow extends StatelessWidget {
  const _ArchivedRow({required this.session, required this.onRestore});
  final Session session;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      leading: AgentAvatar(agent: session.agent),
      title: Text(session.title, overflow: TextOverflow.ellipsis),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: kSpace4),
        child: Wrap(
          spacing: kSpace6,
          runSpacing: kSpace4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (session.branch != null)
              TagChip(label: session.branch!, color: cs.outline),
            if (session.orphaned)
              TagChip(label: 'worktree removed', color: cs.error),
            if (session.lastActivityAt > 0)
              Text(
                _relativeAge(session.lastActivityAt),
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: cs.outline),
              ),
          ],
        ),
      ),
      trailing: TextButton(onPressed: onRestore, child: const Text('Restore')),
    );
  }
}

/// Compact age of an epoch-ms timestamp.
String _relativeAge(int ms) {
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inDays >= 30) return '${(d.inDays / 30).floor()}mo';
  if (d.inDays >= 7) return '${(d.inDays / 7).floor()}w';
  if (d.inDays >= 1) return '${d.inDays}d';
  if (d.inHours >= 1) return '${d.inHours}h';
  return 'now';
}
