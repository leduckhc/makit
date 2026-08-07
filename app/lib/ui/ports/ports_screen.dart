/// SPEC-42 P2a — the global Ports screen ("everything, all repos").
///
/// A new nav destination beside Home / Archived. It renders the
/// `ports.snapshot` the app already receives (no protocol, no scan): an
/// `AppBar`, a filter row (*All / This repo / Mine / Exposed*), and a
/// repo → worktree → port grouped list, with the collapsed "other / system"
/// group for unowned listeners. It holds the ref-counted `ports.watch` while
/// mounted (armed in [initState], released in [dispose]) so the scanner runs
/// only while the screen is up — the same discipline as the worktree row and
/// the desktop sidebar.
///
/// Honesty (SPEC-41 D7): a `scanOk:false` snapshot renders a degraded banner
/// rather than a fake empty list.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/ports.dart';
import '../../store/store.dart';
import 'port_detail_sheet.dart';
import 'ports_filter.dart';
import 'ports_vocabulary.dart';

/// Empty-state marker ("No dev servers running"), keyed for tests.
const Key kPortsEmptyState = ValueKey('ports-empty-state');

/// Degraded-state banner (scan failed), keyed for tests.
const Key kPortsDegradedBanner = ValueKey('ports-degraded-banner');

/// The global Ports screen. [repoId], when set (via `?repo=<id>`), pre-selects
/// the *This repo* filter for that repo.
class PortsScreen extends ConsumerStatefulWidget {
  const PortsScreen({super.key, this.repoId});

  /// The repo to pre-filter to, or null when entered without one.
  final String? repoId;

  @override
  ConsumerState<PortsScreen> createState() => _PortsScreenState();
}

class _PortsScreenState extends ConsumerState<PortsScreen> {
  // Hold the ref-counted ports watch while the screen is mounted, so the server
  // scans `lsof` only while someone is looking (SPEC-41 §Delivery). Fire-and-
  // forget via the injected sink — never `request` (its ack-timeout timer would
  // leak from initState).
  late final PortsWatch _portsWatch = ref.read(portsWatchProvider);

  late PortsFilter _filter = widget.repoId != null
      ? PortsFilter.thisRepo
      : PortsFilter.all;

  /// The "other / system" group starts folded (mockup §6) — system listeners are
  /// noise, not work, so they must not push a branch's dev server off screen.
  bool _systemExpanded = false;

  @override
  void initState() {
    super.initState();
    _portsWatch.watch();
  }

  @override
  void dispose() {
    _portsWatch.release();
    super.dispose();
  }

  void _openPort(PortInfo port, String branchLabel) {
    final sessions = ref.read(sessionsProvider);
    String? sessionLabel(String? id) {
      if (id == null) return null;
      final s = sessions.byId(id);
      if (s == null) return null;
      final t = s.title.trim();
      return t.isNotEmpty ? t : s.agent;
    }

    showPortDetailSheet(
      context,
      port: port,
      branchLabel: branchLabel,
      sessionLabel: sessionLabel(port.sessionId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(portsProvider);
    final repos = ref.watch(reposProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ports'),
        leading: IconButton(
          icon: const Icon(PhosphorIconsLight.arrowLeft),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _FilterRow(
            filter: _filter,
            showThisRepo: widget.repoId != null,
            onChanged: (f) => setState(() => _filter = f),
          ),
          const Divider(height: 1),
          Expanded(child: _body(context, snapshot, repos)),
        ],
      ),
    );
  }

  Widget _body(
    BuildContext context,
    PortsSnapshot? snapshot,
    ReposState repos,
  ) {
    // No frame yet: the watch was just armed; the first snapshot lands shortly.
    // Show a spinner rather than claim "nothing listening" before we know.
    if (snapshot == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final filtered = filterPorts(
      snapshot,
      _filter,
      repos,
      repoId: widget.repoId,
    );
    final grouping = groupByRepoWorktree(filtered, repos);
    final degraded = !snapshot.scanOk;

    // A failed scan cannot prove the list is empty (D7), so it shows a banner —
    // above any ports it did manage to read — never the "nothing listening"
    // empty state.
    if (!degraded && grouping.isEmpty) return _empty(context);

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    return ListView(
      padding: const EdgeInsets.only(bottom: kSpace24),
      children: [
        if (degraded) _DegradedBanner(scanError: snapshot.scanError),
        for (final repo in grouping.repos) ...[
          _GroupHeader(title: repo.repoName, count: _repoPortCount(repo)),
          for (final wt in repo.worktrees) ...[
            _WorktreeHeader(branch: wt.branch, count: wt.ports.length),
            for (final port in wt.ports)
              _PortRow(
                key: ValueKey('ports-screen-row-${port.key}'),
                port: port,
                nowMs: nowMs,
                onTap: () => _openPort(port, wt.branch),
              ),
          ],
        ],
        if (grouping.systemPorts.isNotEmpty) ...[
          _GroupHeader(
            title: 'other / system',
            count: grouping.systemPorts.length,
            // Folded by default (mockup §6): system listeners are noise, not
            // work, and sshd/ControlCenter must not push a branch's dev server
            // off the first screen.
            folded: !_systemExpanded,
            onTap: () => setState(() => _systemExpanded = !_systemExpanded),
          ),
          if (_systemExpanded)
            for (final port in grouping.systemPorts)
              _PortRow(
                key: ValueKey('ports-screen-row-${port.key}'),
                port: port,
                nowMs: nowMs,
                onTap: () => _openPort(port, 'unowned'),
              ),
        ],
      ],
    );
  }

  int _repoPortCount(RepoPortGroup repo) =>
      repo.worktrees.fold(0, (a, w) => a + w.ports.length);

  Widget _empty(BuildContext context) => Center(
    key: kPortsEmptyState,
    child: Padding(
      padding: const EdgeInsets.all(kSpace32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            PhosphorIconsLight.plug,
            size: 48,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: kSpace12),
          Text(
            'No dev servers running.\nStart one and it shows up here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
        ],
      ),
    ),
  );
}

/// The filter chip row (spec §6). *This repo* only appears when the screen was
/// entered with a repo (`?repo=<id>`) — without one there is no repo to filter
/// to, so showing the chip would be a dead affordance.
class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.filter,
    required this.showThisRepo,
    required this.onChanged,
  });

  final PortsFilter filter;
  final bool showThisRepo;
  final ValueChanged<PortsFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[
      _chip('All', PortsFilter.all),
      if (showThisRepo) _chip('This repo', PortsFilter.thisRepo),
      _chip('Mine', PortsFilter.mine),
      _chip('Exposed', PortsFilter.exposed),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(
        horizontal: kSpace12,
        vertical: kSpace8,
      ),
      child: Row(
        children: [
          for (final chip in chips)
            Padding(
              padding: const EdgeInsets.only(right: kSpace6),
              child: chip,
            ),
        ],
      ),
    );
  }

  Widget _chip(String label, PortsFilter value) => ChoiceChip(
    label: Text(label),
    selected: filter == value,
    onSelected: (_) => onChanged(value),
  );
}

/// The degraded banner: an honest "we could not read the sockets" (D7), never a
/// fake empty list.
class _DegradedBanner extends StatelessWidget {
  const _DegradedBanner({required this.scanError});
  final String? scanError;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      key: kPortsDegradedBanner,
      margin: const EdgeInsets.fromLTRB(kSpace12, kSpace12, kSpace12, kSpace4),
      padding: const EdgeInsets.all(kSpace12),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(kRadius8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            PhosphorIconsLight.warning,
            size: 18,
            color: cs.onErrorContainer,
          ),
          const SizedBox(width: kSpace8),
          Expanded(
            child: Text(
              portsScanUnavailableTooltip(scanError),
              style: TextStyle(color: cs.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// A repo (or "other / system") section header — same shape as
/// `archived_screen.dart`'s `_GroupHeader`.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.title,
    required this.count,
    this.folded,
    this.onTap,
  });
  final String title;
  final int count;

  /// Null for a plain, non-foldable header (a repo). Non-null draws a caret and
  /// states which way it points — the system group is the only foldable one.
  final bool? folded;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final row = Padding(
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
          if (folded != null) ...[
            const SizedBox(width: kSpace4),
            Icon(
              folded!
                  ? PhosphorIconsLight.caretRight
                  : PhosphorIconsLight.caretDown,
              size: 14,
              color: theme.colorScheme.outline,
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return row;
    // Semantics: the caret is decorative, the label + state is what a screen
    // reader needs — same rule as the ports glyph (never colour/shape alone).
    return Semantics(
      button: true,
      expanded: folded == false,
      child: InkWell(onTap: onTap, child: row),
    );
  }
}

/// A worktree sub-header inside a repo group: the branch + its port count.
class _WorktreeHeader extends StatelessWidget {
  const _WorktreeHeader({required this.branch, required this.count});
  final String branch;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, kSpace8, 16, kSpace2),
      child: Row(
        children: [
          Icon(PhosphorIconsLight.gitBranch, size: 14, color: cs.primary),
          const SizedBox(width: kSpace6),
          Flexible(
            child: Text(
              branch,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: kSpace8),
          Text(
            '$count',
            style: theme.textTheme.labelSmall?.copyWith(color: cs.outline),
          ),
        ],
      ),
    );
  }
}

/// One tappable port row on the global screen: port number, command token, and
/// a health + reach pill. Tapping opens the P1 detail sheet.
class _PortRow extends StatelessWidget {
  const _PortRow({
    super.key,
    required this.port,
    required this.nowMs,
    required this.onTap,
  });

  final PortInfo port;
  final int nowMs;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, kSpace6, 16, kSpace6),
        child: Row(
          children: [
            SizedBox(
              width: 48,
              child: Text(
                '${port.port}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFamily: kMonoFontFamily,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: kSpace8),
            Expanded(
              child: Text(
                portCommandToken(port.command),
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: kMonoFontFamily,
                ),
              ),
            ),
            const SizedBox(width: kSpace8),
            Text(
              portHealthPill(port.health),
              style: theme.textTheme.labelSmall,
            ),
            const SizedBox(width: kSpace8),
            Text(
              portReachPill(port.reach),
              style: theme.textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
