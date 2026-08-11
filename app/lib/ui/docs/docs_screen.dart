/// SPEC-46 — the global Docs screen (Option A, mockup Card 2).
///
/// A sibling to the Ports screen: an app bar with a count subtitle, a search
/// field (titles AND paths), a filter row (All / Mockups / Specs / Changed with
/// counts), and a repo → worktree grouped list with the branch chip and the
/// coloured left border, mtime-descending within a worktree (D5).
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
  const DocsScreen({super.key});

  @override
  ConsumerState<DocsScreen> createState() => _DocsScreenState();
}

class _DocsScreenState extends ConsumerState<DocsScreen> {
  // Hold the ref-counted docs watch while mounted (D11). Fire-and-forget via
  // the injected sink — never `request` (its ack-timeout timer would leak from
  // initState, the documented trap).
  late final DocsWatch _docsWatch = ref.read(docsWatchProvider);

  DocsFilter _filter = DocsFilter.all;
  String _query = '';

  DocsSnapshot? _countsSnapshot;
  Map<DocsFilter, int> _countsCache = const {};
  String _subtitleCache = '';

  /// [docsFilterCounts] walks every doc; the result changes only when the
  /// snapshot does. Recomputing it per rebuild made each keystroke O(docs).
  /// The subtitle rides the same identity cache: it too walks the whole
  /// snapshot and depends on nothing the query touches.
  Map<DocsFilter, int> _countsFor(DocsSnapshot? snapshot) {
    if (!identical(snapshot, _countsSnapshot)) {
      _countsSnapshot = snapshot;
      _countsCache = docsFilterCounts(snapshot);
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
    final counts = _countsFor(snapshot);

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
    final visible = filterDocs(snapshot, _filter, query: _query);
    final grouping = groupDocsByRepoWorktree(visible, repos);
    if (grouping.isEmpty) return _empty(context);

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    // Flatten the repo → worktree → doc tree into a single builder list so a
    // large aggregate (docs across every repo) builds only the visible rows,
    // the same laziness the popover already enforces.
    final items = <Widget Function()>[];
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

/// The filter chip row (All / Mockups / Specs / Changed), each carrying its
/// count (mockup Card 2). The count rides inside the label so a screen reader
/// reads one string ("Specs 1").
class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.filter,
    required this.counts,
    required this.onChanged,
  });

  final DocsFilter filter;
  final Map<DocsFilter, int> counts;
  final ValueChanged<DocsFilter> onChanged;

  static const _labels = {
    DocsFilter.all: 'All',
    DocsFilter.mockups: 'Mockups',
    DocsFilter.specs: 'Specs',
    DocsFilter.changed: 'Changed',
  };

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: kSpace12),
      child: Row(
        children: [
          for (final f in DocsFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: kSpace6),
              child: ChoiceChip(
                label: Text('${_labels[f]} ${counts[f] ?? 0}'),
                selected: filter == f,
                onSelected: (_) => onChanged(f),
              ),
            ),
        ],
      ),
    );
  }
}

/// A repo section header (mirrors ports_screen's `_GroupHeader`).
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
