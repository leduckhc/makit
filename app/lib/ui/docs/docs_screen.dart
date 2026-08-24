/// SPEC-doc-preview — the global Docs screen (Option A, mockup Card 2).
///
/// A sibling to the Ports screen: an app bar with a count subtitle, a search
/// field (titles AND paths), a filter row (All / This repo / Markdown / Pages /
/// Changed with counts), and a repo → worktree grouped list with the branch
/// chip and the coloured left border, mtime-descending within a worktree (D5).
///
/// Scope (SPEC-docs-scoping-and-board-rework D3): [DocsScreen.repoId], set via
/// `?repo=<id>`, pre-selects the *This repo* filter, exactly like
/// `ports_screen.dart`. A `Recent` group leads the board (D5), and unscoped
/// with more than one repo only the repo owning the newest doc stays expanded
/// (D4).
///
/// Watch-gating (D11): it holds the ref-counted `docs.watch` while mounted
/// (armed in [initState], released in [dispose]) so the index walks only while
/// the screen is up — the same discipline as `ports_screen.dart`. Fire-and-
/// forget `send`, never `request`, so no ack-timeout timer leaks from
/// [initState].
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/docs.dart';
import '../../store/store.dart';
import 'doc_preview.dart';
import 'doc_row.dart';
import 'docs_filter.dart';

/// Empty-state marker, keyed for tests.
const Key kDocsEmptyState = ValueKey('docs-empty-state');

/// The global Docs screen.
class DocsScreen extends ConsumerStatefulWidget {
  const DocsScreen({super.key, this.repoId});

  /// The repo to pre-filter to, or null when entered without one (D3).
  final String? repoId;

  @override
  ConsumerState<DocsScreen> createState() => _DocsScreenState();
}

class _DocsScreenState extends ConsumerState<DocsScreen> {
  // Hold the ref-counted docs watch while mounted (D11). Fire-and-forget via
  // the injected sink — never `request` (its ack-timeout timer would leak from
  // initState, the documented trap).
  late final DocsWatch _docsWatch = ref.read(docsWatchProvider);

  // Scoped entry pre-selects *This repo*; unscoped starts on *All* — the
  // `ports_screen.dart` rule.
  late DocsFilter _filter = widget.repoId != null
      ? DocsFilter.thisRepo
      : DocsFilter.all;
  String _query = '';

  /// User overrides of a repo group's fold state (D4). Absent means "use the
  /// default": only the repo owning the newest doc is open.
  final Map<String, bool> _repoExpandedOverride = {};

  DocsSnapshot? _countsSnapshot;
  ReposState? _countsRepos;
  Map<DocsFilter, int> _countsCache = const {};
  String _subtitleCache = '';

  /// [docsFilterCounts] walks every doc; the result changes only when the
  /// snapshot or the repo set does. Recomputing it per rebuild made each
  /// keystroke O(docs). The subtitle rides the same identity cache.
  Map<DocsFilter, int> _countsFor(DocsSnapshot? snapshot, ReposState repos) {
    if (!identical(snapshot, _countsSnapshot) ||
        !identical(repos, _countsRepos)) {
      _countsSnapshot = snapshot;
      _countsRepos = repos;
      _countsCache = docsFilterCounts(snapshot, repos, repoId: widget.repoId);
      _subtitleCache = snapshot == null ? '' : _subtitle(snapshot);
    }
    return _countsCache;
  }

  @override
  void initState() {
    super.initState();
    _docsWatch.watch();
  }

  @override
  void dispose() {
    _docsWatch.release();
    super.dispose();
  }

  void _open(DocInfo doc) => showDocPreviewSheet(context, doc);

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(docsProvider);
    final repos = ref.watch(reposProvider);
    // Counts describe the whole snapshot, not the query, so they must not be
    // recomputed on every keystroke — memoised against the snapshot identity.
    final counts = _countsFor(snapshot, repos);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Docs'),
            if (snapshot != null)
              Text(
                _subtitleCache,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        leading: IconButton(
          icon: const Icon(PhosphorIconsLight.arrowLeft),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SearchField(onChanged: (v) => setState(() => _query = v)),
          _FilterRow(
            filter: _filter,
            counts: counts,
            showThisRepo: widget.repoId != null,
            onChanged: (f) => setState(() => _filter = f),
          ),
          const Divider(height: 1),
          Expanded(child: _body(context, snapshot, repos)),
        ],
      ),
    );
  }

  String _subtitle(DocsSnapshot snapshot) {
    final files = snapshot.docs.length;
    final worktrees = snapshot.docs.map((d) => d.worktreePath).toSet().length;
    final changed = snapshot.docs.where((d) => d.changed == true).length;
    final f = files == 1 ? '1 file' : '$files files';
    final w = worktrees == 1 ? '1 worktree' : '$worktrees worktrees';
    return '$f · $w · $changed changed';
  }

  Widget _body(BuildContext context, DocsSnapshot? snapshot, ReposState repos) {
    // No frame yet: the watch was just armed; show a spinner rather than claim
    // "no docs" before the first snapshot lands.
    if (snapshot == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final visible = filterDocs(
      snapshot,
      _filter,
      repos,
      repoId: widget.repoId,
      query: _query,
    );
    final grouping = groupDocsByRepoWorktree(visible, repos);
    if (grouping.isEmpty) return _empty(context);

    final nowMs = DateTime.now().millisecondsSinceEpoch;

    // Docs that survived D6 (their worktree is active), flattened so the Recent
    // group never lists a dead link.
    final groupedDocs = [
      for (final repo in grouping.repos)
        for (final wt in repo.worktrees) ...wt.docs,
    ];
    // D5: the doc you want is the one you just made — recency answers *which*,
    // above the grouping that answers *where*.
    final recent = recentDocs(groupedDocs);

    // D4: unscoped with more than one repo, only the repo owning the newest doc
    // stays open; the rest fold to a counted header — the `_systemExpanded`
    // folding precedent from `ports_screen.dart`.
    final foldingActive = widget.repoId == null && grouping.repos.length > 1;
    final defaultOpenId = foldingActive
        ? repoIdOwningNewestDoc(grouping)
        : null;

    // Flatten the tree into a single builder list so a large aggregate builds
    // only the visible rows, the same laziness the popover enforces.
    final items = <Widget Function()>[];

    items.add(() => _GroupHeader(title: 'Recent', count: recent.length));
    for (final doc in recent) {
      items.add(
        () => DocRow(
          // A distinct key from the grouped copy below, so the same doc can
          // appear in Recent and its group without a duplicate key.
          key: ValueKey('docs-recent-row-${doc.key}'),
          doc: doc,
          nowMs: nowMs,
          onTap: () => _open(doc),
          pathStyle: DocPathStyle.absolute,
        ),
      );
    }

    for (final repo in grouping.repos) {
      final expanded =
          !foldingActive ||
          (_repoExpandedOverride[repo.repoId] ??
              (repo.repoId == defaultOpenId));
      items.add(
        () => _GroupHeader(
          title: repo.repoName,
          count: repo.worktrees.fold(0, (a, w) => a + w.docs.length),
          // A caret only when folding is active; a scoped or single-repo board
          // has nothing to fold.
          folded: foldingActive ? !expanded : null,
          onTap: foldingActive
              ? () => setState(
                  () => _repoExpandedOverride[repo.repoId] = !expanded,
                )
              : null,
        ),
      );
      if (expanded) {
        for (final wt in repo.worktrees) {
          items.add(
            () => _WorktreeHeader(branch: wt.branch, count: wt.docs.length),
          );
          for (final doc in wt.docs) {
            items.add(
              () => DocRow(
                key: ValueKey('docs-screen-row-${doc.key}'),
                doc: doc,
                nowMs: nowMs,
                onTap: () => _open(doc),
                pathStyle: DocPathStyle.absolute,
              ),
            );
          }
        }
      }
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: kSpace24),
      itemCount: items.length,
      itemBuilder: (context, i) => items[i](),
    );
  }

  Widget _empty(BuildContext context) => Center(
    key: kDocsEmptyState,
    child: Padding(
      padding: const EdgeInsets.all(kSpace32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            PhosphorIconsLight.fileDashed,
            size: 48,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: kSpace12),
          Text(
            _query.isEmpty
                ? 'No docs here yet.\nWrite a spec or a mockup and it shows up.'
                : 'No docs match “$_query”.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
        ],
      ),
    ),
  );
}

/// The search field (titles AND paths). A plain [TextField]; the screen
/// debounces nothing — the list is already in memory (P1 does no doc-body
/// search).
class _SearchField extends StatelessWidget {
  const _SearchField({required this.onChanged});
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(kSpace12, kSpace8, kSpace12, kSpace8),
      child: TextField(
        onChanged: onChanged,
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(PhosphorIconsLight.magnifyingGlass, size: 18),
          hintText: 'Search titles and paths',
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(kRadius10),
          ),
        ),
      ),
    );
  }
}

/// The filter chip row (All / This repo / Markdown / Pages / Changed), each
/// kind chip carrying its count. *This repo* only appears when the board was
/// entered with a repo (`?repo=<id>`) — without one there is no repo to filter
/// to, so the chip would be a dead affordance (the `ports_screen.dart` rule).
class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.filter,
    required this.counts,
    required this.showThisRepo,
    required this.onChanged,
  });

  final DocsFilter filter;
  final Map<DocsFilter, int> counts;
  final bool showThisRepo;
  final ValueChanged<DocsFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[
      _chip('All', DocsFilter.all),
      // No count on *This repo*: it is a scope, not a bucket to eyeball — the
      // same choice `ports_screen.dart` makes for its *This repo* chip.
      if (showThisRepo)
        _chip('This repo', DocsFilter.thisRepo, showCount: false),
      _chip('Markdown', DocsFilter.markdown),
      _chip('Pages', DocsFilter.pages),
      _chip('Changed', DocsFilter.changed),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: kSpace12),
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

  Widget _chip(String label, DocsFilter value, {bool showCount = true}) =>
      ChoiceChip(
        // The count rides inside the label so a screen reader reads one string
        // ("Markdown 27"), not a decorative badge read separately.
        label: Text(showCount ? '$label ${counts[value] ?? 0}' : label),
        selected: filter == value,
        onSelected: (_) => onChanged(value),
      );
}

/// A repo section header (mirrors ports_screen's `_GroupHeader`). [folded] is
/// null for a plain, non-foldable header; non-null draws a caret and states
/// which way it points, so the unscoped multi-repo board can fold the repos it
/// does not open by default (D4).
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.title,
    required this.count,
    this.folded,
    this.onTap,
  });
  final String title;
  final int count;
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
    // Semantics: the caret is decorative; the label + state is what a screen
    // reader needs — the `ports_screen.dart` rule.
    return Semantics(
      button: true,
      expanded: folded == false,
      child: InkWell(onTap: onTap, child: row),
    );
  }
}

/// A worktree sub-header: the branch chip and its doc count, with the coloured
/// left border (mockup `.wtsub` accent). Every worktree header carries the
/// primary-tinted border — the list groups by worktree without an
/// active/inactive distinction, so there is no flag to tint one over another.
class _WorktreeHeader extends StatelessWidget {
  const _WorktreeHeader({required this.branch, required this.count});
  final String branch;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: cs.primary, width: 3)),
      ),
      padding: const EdgeInsets.fromLTRB(21, kSpace8, 16, kSpace2),
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
