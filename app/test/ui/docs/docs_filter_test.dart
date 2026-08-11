import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/docs.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/docs/docs_filter.dart';

DocInfo _doc(
  String relPath, {
  String worktreePath = '/repo/a',
  DocKind kind = DocKind.md,
  int modifiedAt = 0,
  bool? changed,
  String title = 'Doc',
}) => DocInfo(
  key: '$worktreePath:$relPath',
  relPath: relPath,
  title: title,
  kind: kind,
  bytes: 10,
  modifiedAt: modifiedAt,
  worktreePath: worktreePath,
  changed: changed,
);

DocsSnapshot _snap(List<DocInfo> docs) =>
    DocsSnapshot(docs: docs, scannedAt: 0, scanOk: true);

ReposState _repos() => ReposState([
  const RepoInfo(
    id: 'r1',
    name: 'makit',
    path: '/repo',
    pinned: false,
    lastActivityAt: 0,
    isGitRepo: true,
    defaultBranch: 'main',
    currentBranch: 'main',
    worktrees: [
      Worktree(
        id: 'w1',
        path: '/repo/a',
        branch: 'feat/a',
        isPrimary: false,
        insertions: 0,
        deletions: 0,
        filesChanged: 0,
        sessionIds: [],
      ),
      Worktree(
        id: 'w2',
        path: '/repo/b',
        branch: 'main',
        isPrimary: true,
        insertions: 0,
        deletions: 0,
        filesChanged: 0,
        sessionIds: [],
      ),
    ],
  ),
]);

void main() {
  group('filterDocs', () {
    final docs = [
      _doc('mockups/x.html', kind: DocKind.html),
      _doc('docs/specs/s.md'),
      _doc('README.md'),
      _doc('docs/plan.md', changed: true),
    ];

    test('all keeps everything', () {
      expect(filterDocs(_snap(docs), DocsFilter.all), hasLength(4));
    });

    test('mockups keeps only files under mockups/', () {
      final r = filterDocs(_snap(docs), DocsFilter.mockups);
      expect(r.map((d) => d.relPath), ['mockups/x.html']);
    });

    test('specs keeps only files under docs/', () {
      final r = filterDocs(_snap(docs), DocsFilter.specs);
      expect(r.map((d) => d.relPath), ['docs/specs/s.md', 'docs/plan.md']);
    });

    test('changed keeps only changed==true', () {
      final r = filterDocs(_snap(docs), DocsFilter.changed);
      expect(r.map((d) => d.relPath), ['docs/plan.md']);
    });

    test('a null snapshot yields no docs, never a fabricated list', () {
      // _DocsScreenState._body relies on this branch to show a waiting state
      // rather than an empty-docs claim before the first snapshot lands.
      expect(filterDocs(null, DocsFilter.all), isEmpty);
      expect(docsFilterCounts(null)[DocsFilter.all], 0);
    });

    test('search matches title OR path, case-insensitively', () {
      final r = filterDocs(
        _snap([
          _doc('docs/a.md', title: 'Ports forward'),
          _doc('mockups/ports.html', title: 'Board', kind: DocKind.html),
          _doc('docs/other.md', title: 'Something'),
        ]),
        DocsFilter.all,
        query: 'PORT',
      );
      expect(
        r.map((d) => d.relPath),
        containsAll(['docs/a.md', 'mockups/ports.html']),
      );
      expect(r.map((d) => d.relPath), isNot(contains('docs/other.md')));
    });
  });

  group('filter counts', () {
    test('count each filter independently of the active one', () {
      final snap = _snap([
        _doc('mockups/x.html', kind: DocKind.html),
        _doc('docs/s.md', changed: true),
        _doc('README.md'),
      ]);
      final counts = docsFilterCounts(snap);
      expect(counts[DocsFilter.all], 3);
      expect(counts[DocsFilter.mockups], 1);
      expect(counts[DocsFilter.specs], 1);
      expect(counts[DocsFilter.changed], 1);
    });
  });

  group('groupDocsByRepoWorktree', () {
    test('groups repo → worktree, mtime-descending within a worktree', () {
      final snap = _snap([
        _doc('a.md', worktreePath: '/repo/a', modifiedAt: 10),
        _doc('b.md', worktreePath: '/repo/a', modifiedAt: 30),
        _doc('c.md', worktreePath: '/repo/b', modifiedAt: 20),
      ]);
      final grouping = groupDocsByRepoWorktree(
        filterDocs(snap, DocsFilter.all),
        _repos(),
      );
      expect(grouping.repos, hasLength(1));
      final wts = grouping.repos.single.worktrees;
      expect(wts.map((w) => w.branch), ['feat/a', 'main']);
      // mtime-desc inside the first worktree.
      expect(wts.first.docs.map((d) => d.relPath), ['b.md', 'a.md']);
    });

    test('a doc whose worktree is not active is dropped (D6)', () {
      final snap = _snap([_doc('x.md', worktreePath: '/gone')]);
      final grouping = groupDocsByRepoWorktree(
        filterDocs(snap, DocsFilter.all),
        _repos(),
      );
      expect(grouping.repos, isEmpty);
    });
  });
}
