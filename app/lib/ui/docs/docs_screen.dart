/// SPEC-doc-preview — the global Docs screen (Option A, mockup Card 2).
///
/// A sibling to the Ports screen: an app bar with a count subtitle, a search
/// field (titles AND paths), a filter row (All / This repo / Markdown / Pages /
/// Changed with counts), and a repo → worktree grouped list with the branch
/// chip and the coloured left border, mtime-descending within a worktree (D5).
///
/// Scope (SPEC-docs-scoping-and-board-rework D8): the board shows exactly one
/// project. The effective repo is [DocsScreen.repoId] (from `?repo=<id>`) when
/// set, else the repo owning the newest doc. Every list on screen — `Recent`,
/// the worktree groups, and the chip counts — is drawn from that project alone;
/// another project is never rendered. Switching project is an explicit act
/// through an app-bar menu; the choice is view state and is never persisted.
/// A `Recent` group leads the board (D5).
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

  // The filter always starts on *All* — under D8 the board is one project, so
  // *All* means "all docs in this project" (D9). There is no scope chip.
  DocsFilter _filter = DocsFilter.all;
  String _query = '';

  /// The project the user picked from the app-bar menu (D8), or null to use the
  /// default (the repo owning the newest doc). View state only; never
  /// persisted, and ignored when [DocsScreen.repoId] scopes the route.
  String? _selectedRepoId;

  // Scope cache: the projects that own docs and the default project both depend
  // only on the snapshot + repo-set identity, not on the query or filter, so
  // they must not be recomputed per keystroke.
  DocsSnapshot? _scopeSnapshot;
  ReposState? _scopeRepos;
  List<RepoDocGroup> _projectsWithDocs = const [];
  String? _defaultRepoId;

  DocsSnapshot? _countsSnapshot;
  ReposState? _countsRepos;
  String? _countsRepoId;
  Map<DocsFilter, int> _countsCache = const {};
  String _subtitleCache = '';

  /// Recompute the project set and the default project when the snapshot or the
  /// repo set changes identity. Grouping the whole snapshot is O(docs), so it
  /// rides the same identity cache the counts use.
  void _recomputeScope(DocsSnapshot? snapshot, ReposState repos) {
    if (identical(snapshot, _scopeSnapshot) && identical(repos, _scopeRepos)) {
      return;
    }
    _scopeSnapshot = snapshot;
    _scopeRepos = repos;
    final grouping = snapshot == null
        ? const DocsGrouping(repos: [])
        : groupDocsByRepoWorktree(snapshot.docs, repos);
    _projectsWithDocs = grouping.repos;
    _defaultRepoId = repoIdOwningNewestDoc(grouping);
  }

  /// The one project the board shows (D8): the route scope wins; else the
  /// user's menu pick, if it still owns docs; else the repo owning the newest
  /// doc.
  /// The project the board renders (D8). The user's menu pick wins, then the
  /// route scope (`?repo=`), then the repo owning the newest doc.
  ///
  /// The pick must outrank the route: the only navigation here
  /// (`worktree_docs_sheet.dart`) always passes `?repo=`, so if the route won,
  /// the switcher could never change anything in the shipped app.
  String? _effectiveRepoId() {
    if (_selectedRepoId != null &&
        _projectsWithDocs.any((r) => r.repoId == _selectedRepoId)) {
      return _selectedRepoId;
    }
    if (widget.repoId != null) return widget.repoId;
    return _defaultRepoId;
  }

  /// [docsFilterCounts] walks every doc; the result changes only when the
  /// snapshot, the repo set, or the effective project changes. Recomputing it
  /// per rebuild made each keystroke O(docs). The subtitle rides the same
  /// identity cache.
  Map<DocsFilter, int> _countsFor(
    DocsSnapshot? snapshot,
    ReposState repos,
    String? effectiveRepoId,
  ) {
    if (!identical(snapshot, _countsSnapshot) ||
        !identical(repos, _countsRepos) ||
        effectiveRepoId != _countsRepoId) {
      _countsSnapshot = snapshot;
      _countsRepos = repos;
      _countsRepoId = effectiveRepoId;
      _countsCache = docsFilterCounts(snapshot, repos, repoId: effectiveRepoId);
      _subtitleCache = snapshot == null
          ? ''
          : _subtitle(
              filterDocs(
                snapshot,
                DocsFilter.all,
                repos,
                repoId: effectiveRepoId,
              ),
            );
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
    _recomputeScope(snapshot, repos);
    final effectiveRepoId = _effectiveRepoId();
    // Counts describe the active project, not the query, so they must not be
    // recomputed on every keystroke — memoised against the identity triple.
    final counts = _countsFor(snapshot, repos, effectiveRepoId);

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
        actions: [_projectMenu(context, effectiveRepoId)],
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
            onChanged: (f) => setState(() => _filter = f),
          ),
          const Divider(height: 1),
          Expanded(child: _body(context, snapshot, repos, effectiveRepoId)),
        ],
      ),
    );
  }

  /// The app-bar project switcher (D8). It names the active project and lists
  /// every project that owns docs.
  ///
  /// It shows on a route-scoped board too. Every navigation here passes
  /// `?repo=`, so gating it on an unscoped board left it unreachable in the
  /// shipped app — a dead surface, and the user still needs a way to the other
  /// project's docs without backing out through two screens. Hidden only when
  /// one project owns docs, where there is nothing to switch to.
  Widget _projectMenu(BuildContext context, String? effectiveRepoId) {
    if (_projectsWithDocs.length < 2) {
      return const SizedBox.shrink();
    }
    String? active;
    for (final repo in _projectsWithDocs) {
      if (repo.repoId == effectiveRepoId) {
        active = repo.repoName;
        break;
      }
    }
    final theme = Theme.of(context);
    return PopupMenuButton<String>(
      tooltip: 'Switch project',
      onSelected: (id) => setState(() => _selectedRepoId = id),
      itemBuilder: (context) => [
        for (final repo in _projectsWithDocs)
          PopupMenuItem<String>(
            value: repo.repoId,
            child: Row(
              children: [
                Icon(
                  repo.repoId == effectiveRepoId
                      ? PhosphorIconsLight.check
                      : PhosphorIconsLight.folder,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: kSpace8),
                Text(repo.repoName),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: kSpace12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                active ?? 'Project',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge,
              ),
            ),
            const Icon(PhosphorIconsLight.caretDown, size: 14),
          ],
        ),
      ),
    );
  }

  String _subtitle(List<DocInfo> docs) {
    final files = docs.length;
    final worktrees = docs.map((d) => d.worktreePath).toSet().length;
    final changed = docs.where((d) => d.changed == true).length;
    final f = files == 1 ? '1 file' : '$files files';
    final w = worktrees == 1 ? '1 worktree' : '$worktrees worktrees';
    return '$f · $w · $changed changed';
  }

  Widget _body(
    BuildContext context,
    DocsSnapshot? snapshot,
    ReposState repos,
    String? effectiveRepoId,
  ) {
    // No frame yet: the watch was just armed; show a spinner rather than claim
    // "no docs" before the first snapshot lands.
    if (snapshot == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final visible = filterDocs(
      snapshot,
      _filter,
      repos,
      repoId: effectiveRepoId,
      query: _query,
    );
    final grouping = groupDocsByRepoWorktree(visible, repos);
    if (grouping.isEmpty) return _empty(context);

    final nowMs = DateTime.now().millisecondsSinceEpoch;

    // Every doc on screen belongs to the one active project (D8), flattened so
    // the Recent group never lists a dead link and never a foreign project.
    final groupedDocs = [
      for (final repo in grouping.repos)
        for (final wt in repo.worktrees) ...wt.docs,
    ];
    // D5: the doc you want is the one you just made — recency answers *which*,
    // above the grouping that answers *where*.
    final recent = recentDocs(groupedDocs);

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
      items.add(
        () => _GroupHeader(
          title: repo.repoName,
          count: repo.worktrees.fold(0, (a, w) => a + w.docs.length),
        ),
      );
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

/// The filter chip row (All / Markdown / Pages / Changed), each carrying its
/// count. Under D8 the board is always one project, so `All` means "all docs
/// in this project" and there is no scope chip (D9).
class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.filter,
    required this.counts,
    required this.onChanged,
  });

  final DocsFilter filter;
  final Map<DocsFilter, int> counts;
  final ValueChanged<DocsFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[
      _chip('All', DocsFilter.all),
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

  Widget _chip(String label, DocsFilter value) => ChoiceChip(
    // The count rides inside the label so a screen reader reads one string
    // ("Markdown 27"), not a decorative badge read separately.
    label: Text('$label ${counts[value] ?? 0}'),
    selected: filter == value,
    onSelected: (_) => onChanged(value),
  );
}

/// A repo section header (mirrors ports_screen's `_GroupHeader`). Under D8 the
/// board shows one project, so a section header no longer folds — it is a plain
/// label with a count.
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
