import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../store/models.dart';
import '../../store/store.dart';
import '../../status/status_event.dart';
import '../../status/status_providers.dart';

/// Whether the sidebar shows the Active tree or the Closed list (SPEC-29).
final sidebarClosedProvider = StateProvider<bool>((_) => false);

/// How the closed list is grouped.
enum ClosedGroupBy { repo, branch, age, harness }

extension on ClosedGroupBy {
  String get label => switch (this) {
    ClosedGroupBy.repo => 'Repo',
    ClosedGroupBy.branch => 'Branch',
    ClosedGroupBy.age => 'Age',
    ClosedGroupBy.harness => 'Harness',
  };
}

/// The Closed view that replaces the repo tree when the sidebar is in
/// closed mode. Loads closed sessions on demand and groups them by the
/// chosen dimension; each row restores back to the active list.
class ClosedSidebarView extends ConsumerStatefulWidget {
  const ClosedSidebarView({super.key});

  @override
  ConsumerState<ClosedSidebarView> createState() => _ClosedSidebarViewState();
}

class _ClosedSidebarViewState extends ConsumerState<ClosedSidebarView> {
  ClosedGroupBy _by = ClosedGroupBy.repo;
  late Future<List<Session>> _future = _load();

  Future<List<Session>> _load() =>
      ref.read(storeControllerProvider.notifier).listClosedSessions();

  // Guard for the live-sync listener below: the set of active session ids the
  // last snapshot carried, so routine activity/status churn doesn't trigger a
  // reload — only an actual close/reopen (which adds/removes an id) does.
  //
  // Seeded in [initState] rather than left null, for the same reason the mobile
  // ClosedScreen seeds it: the listener only fires on a *change*, so an unseeded
  // baseline swallows the FIRST one — close a session from a chat pane with this
  // view open and the list stayed stale until a manual toggle. Seeding it *empty*
  // is not enough either, or the next snapshot always looks like a change and
  // reloads for nothing, so it starts from what the store already holds.
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
    setState(() {
      _future = _load();
    });
  }

  Future<void> _reopen(String id) async {
    final status = ref.status;
    try {
      await ref.read(storeControllerProvider.notifier).reopenSession(id);
      if (!mounted) return;
      // Refresh immediately for snappy local feedback. The sessionsProvider
      // listener in build() also fires once the server re-broadcasts the active
      // set (the cross-pane path), so a local restore reloads twice — harmless
      // and intentional: the listener alone isn't guaranteed same-frame.
      _refresh();
    } catch (e) {
      status.failure(
        'Could not reopen the session',
        error: e,
        source: StatusSources.session,
        sessionId: id,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Live-sync: closing/reopening a session elsewhere (e.g. from a chat
    // pane) changes the ACTIVE session set the server broadcasts. Reload the
    // closed list on that transition so it stays fresh without the user
    // toggling the view. Keyed on the id SET (order-independent, no sort/join)
    // so this stays allocation-light under frequent broadcasts from many live
    // sessions and only fires on a real add/remove, not activity/status churn.
    ref.listen<SessionsState>(sessionsProvider, (_, next) {
      final ids = {for (final s in next.sessions) s.id};
      final prev = _lastActiveIds;
      if (ids.length != prev.length || !ids.containsAll(prev)) {
        _refresh();
      }
      _lastActiveIds = ids;
    });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _controls(context),
        const Divider(height: 1),
        Expanded(
          child: FutureBuilder<List<Session>>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting &&
                  !snap.hasData) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                );
              }
              if (snap.hasError) return _error(context);
              final sessions = snap.data ?? const <Session>[];
              if (sessions.isEmpty) return _empty(context);
              return _grouped(context, sessions);
            },
          ),
        ),
      ],
    );
  }

  Widget _controls(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          Icon(PhosphorIconsLight.moon, size: 15, color: cs.outline),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'CLOSED',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: cs.outline,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.9,
              ),
            ),
          ),
          const SizedBox(width: 8),
          _GroupByMenu(value: _by, onChanged: (v) => setState(() => _by = v)),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Text(
          'No closed sessions.',
          style: TextStyle(color: cs.outline, fontSize: 12.5),
        ),
      ),
    );
  }

  Widget _error(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(PhosphorIconsLight.warningCircle, size: 20, color: cs.error),
            const SizedBox(height: 8),
            Text(
              "Couldn't load closed sessions.",
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5),
            ),
            const SizedBox(height: 10),
            TextButton(onPressed: _refresh, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }

  Widget _grouped(BuildContext context, List<Session> sessions) {
    final groups = _group(sessions, _by, ref);
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 12, top: 4),
      itemCount: groups.length,
      itemBuilder: (context, i) {
        final g = groups[i];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _GroupHeader(
              title: g.title,
              subtitle: g.subtitle,
              count: g.items.length,
            ),
            for (final s in g.items)
              _ClosedRow(
                session: s,
                groupBy: _by,
                onReopen: () => _reopen(s.id),
              ),
          ],
        );
      },
    );
  }
}

// ---------- grouping ----------

class _Group {
  _Group(this.title, this.subtitle);
  final String title;
  final String? subtitle;
  final List<Session> items = [];
}

List<_Group> _group(List<Session> sessions, ClosedGroupBy by, WidgetRef ref) {
  final repos = ref.read(reposProvider);
  String repoName(String pid) => repos.byId(pid)?.name ?? pid;

  ({String key, String title, String? sub}) keyOf(Session s) => switch (by) {
    ClosedGroupBy.repo => (
      key: s.projectId,
      title: repoName(s.projectId),
      sub: null,
    ),
    ClosedGroupBy.branch => (
      key: '${s.projectId}/${s.branch ?? '∅'}',
      title: s.branch ?? 'detached',
      sub: repoName(s.projectId),
    ),
    ClosedGroupBy.age => (
      key: _ageBucket(s).$1,
      title: _ageBucket(s).$2,
      sub: null,
    ),
    ClosedGroupBy.harness => (
      key: s.agent,
      title: s.agent == 'pi' ? 'Pi' : (s.agent == 'codex' ? 'Codex' : s.agent),
      sub: null,
    ),
  };

  final map = <String, _Group>{};
  final order = <String>[];
  for (final s in sessions) {
    final k = keyOf(s);
    final g = map.putIfAbsent(k.key, () {
      order.add(k.key);
      return _Group(k.title, k.sub);
    });
    g.items.add(s);
  }

  // Age groups get a fixed chronological order; others keep first-seen (the
  // server already sorts newest-first), which reads well for repo/branch/harness.
  if (by == ClosedGroupBy.age) {
    const rank = {'today': 0, 'week': 1, 'month': 2, 'older': 3};
    order.sort((a, b) => (rank[a] ?? 9).compareTo(rank[b] ?? 9));
  }
  for (final g in map.values) {
    g.items.sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
  }
  return [for (final k in order) map[k]!];
}

/// (bucketKey, label) for a session's last-activity age.
(String, String) _ageBucket(Session s) {
  final now = DateTime.now();
  final at = DateTime.fromMillisecondsSinceEpoch(s.lastActivityAt);
  final days = now.difference(at).inDays;
  if (at.year == now.year && at.month == now.month && at.day == now.day) {
    return ('today', 'Today');
  }
  if (days < 7) return ('week', 'This week');
  if (days < 30) return ('month', 'Last 30 days');
  return ('older', 'Older');
}

String _relativeAge(int ms) {
  if (ms == 0) return '';
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inDays >= 30) return '${(d.inDays / 30).floor()}mo';
  if (d.inDays >= 7) return '${(d.inDays / 7).floor()}w';
  if (d.inDays >= 1) return '${d.inDays}d';
  if (d.inHours >= 1) return '${d.inHours}h';
  return 'now';
}

// ---------- rows ----------

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.title, this.subtitle, required this.count});
  final String title;
  final String? subtitle;
  final int count;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 4),
      child: Row(
        children: [
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(color: cs.outline),
              ),
            ),
          ],
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '$count',
              style: theme.textTheme.labelSmall?.copyWith(color: cs.outline),
            ),
          ),
        ],
      ),
    );
  }
}

class _ClosedRow extends StatefulWidget {
  const _ClosedRow({
    required this.session,
    required this.groupBy,
    required this.onReopen,
  });
  final Session session;
  final ClosedGroupBy groupBy;
  final VoidCallback onReopen;

  @override
  State<_ClosedRow> createState() => _ClosedRowState();
}

class _ClosedRowState extends State<_ClosedRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final harnessColor = s.agent == 'codex'
        ? const Color(0xFF7AA2F7)
        : cs.primary;
    final showBranch =
        widget.groupBy != ClosedGroupBy.branch && s.branch != null;
    final showHarness = widget.groupBy != ClosedGroupBy.harness;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        margin: const EdgeInsets.fromLTRB(8, 1, 8, 1),
        padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
        decoration: BoxDecoration(
          color: _hover ? cs.surfaceContainerHigh : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(fontSize: 12.5),
                  ),
                  const SizedBox(height: 3),
                  Wrap(
                    spacing: 5,
                    runSpacing: 3,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (showHarness)
                        _Chip(
                          s.agent == 'pi'
                              ? 'Pi'
                              : (s.agent == 'codex' ? 'Codex' : s.agent),
                          color: harnessColor,
                        ),
                      if (showBranch) _Chip(s.branch!, mono: true),
                      if (s.orphaned)
                        _Chip('worktree removed', color: cs.error),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Text(
              _relativeAge(s.lastActivityAt),
              style: theme.textTheme.labelSmall?.copyWith(color: cs.outline),
            ),
            // Always present (not hover-gated) so keyboard-only users can focus
            // and restore. Dimmed until the row is hovered/focused.
            IconButton(
              tooltip: 'Reopen',
              iconSize: 15,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
              icon: const Icon(PhosphorIconsLight.arrowCounterClockwise),
              color: _hover ? cs.primary : cs.outline,
              onPressed: widget.onReopen,
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.text, {this.color, this.mono = false});
  final String text;
  final Color? color;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = color ?? cs.outline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.withValues(alpha: 0.4)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          height: 1.3,
          color: c,
          fontFamily: mono ? 'SF Mono' : null,
          fontFamilyFallback: mono ? const ['monospace'] : null,
        ),
      ),
    );
  }
}

class _GroupByMenu extends StatelessWidget {
  const _GroupByMenu({required this.value, required this.onChanged});
  final ClosedGroupBy value;
  final ValueChanged<ClosedGroupBy> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopupMenuButton<ClosedGroupBy>(
      tooltip: 'Group by',
      initialValue: value,
      onSelected: onChanged,
      position: PopupMenuPosition.under,
      itemBuilder: (context) => [
        for (final v in ClosedGroupBy.values)
          PopupMenuItem(
            value: v,
            height: 36,
            child: Text(v.label, style: Theme.of(context).textTheme.bodyMedium),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Group: ${value.label}',
              style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
            ),
            const SizedBox(width: 3),
            Icon(
              PhosphorIconsLight.caretDown,
              size: 12,
              color: cs.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
