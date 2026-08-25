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
  final repos = _repos();

  group('filterDocs', () {
    final docs = [
      _doc('mockups/x.html', kind: DocKind.html),
      _doc('docs/specs/s.md'),
      _doc('README.md'),
      _doc('docs/plan.md', changed: true),
    ];

    test('all keeps everything', () {
      expect(filterDocs(_snap(docs), DocsFilter.all, repos), hasLength(4));
    });

    test('markdown keeps only kind==md (never a path)', () {
      final r = filterDocs(_snap(docs), DocsFilter.markdown, repos);
      expect(r.map((d) => d.relPath), [
        'docs/specs/s.md',
        'README.md',
        'docs/plan.md',
      ]);
    });

    test('pages keeps only kind==html (never a path)', () {
      final r = filterDocs(_snap(docs), DocsFilter.pages, repos);
      expect(r.map((d) => d.relPath), ['mockups/x.html']);
    });

    test('changed keeps only changed==true', () {
      final r = filterDocs(_snap(docs), DocsFilter.changed, repos);
      expect(r.map((d) => d.relPath), ['docs/plan.md']);
    });

    test('repoId scopes every filter to that project (D8/D9)', () {
      final scoped = _snap([
        _doc('a.md', worktreePath: '/repo/a'),
        _doc('b.md', worktreePath: '/repo/b'),
        _doc('gone.md', worktreePath: '/elsewhere'),
      ]);
      // Scoped to r1: only docs whose worktree belongs to r1 survive.
      expect(
        filterDocs(
          scoped,
          DocsFilter.all,
          repos,
          repoId: 'r1',
        ).map((d) => d.relPath),
        ['a.md', 'b.md'],
      );
      // Unscoped: filterDocs keeps every doc; the screen always passes the
      // effective repoId, and grouping later drops any foreign worktree.
      expect(filterDocs(scoped, DocsFilter.all, repos).map((d) => d.relPath), [
        'a.md',
        'b.md',
        'gone.md',
      ]);
    });

    test('a null snapshot yields no docs, never a fabricated list', () {
      // _DocsScreenState._body relies on this branch to show a waiting state
      // rather than an empty-docs claim before the first snapshot lands.
      expect(filterDocs(null, DocsFilter.all, repos), isEmpty);
      expect(docsFilterCounts(null, repos)[DocsFilter.all], 0);
    });

    test('search matches title OR path, case-insensitively', () {
      final r = filterDocs(
        _snap([
          _doc('docs/a.md', title: 'Ports forward'),
          _doc('mockups/ports.html', title: 'Board', kind: DocKind.html),
          _doc('docs/other.md', title: 'Something'),
        ]),
        DocsFilter.all,
        repos,
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
      final counts = docsFilterCounts(snap, repos);
      expect(counts[DocsFilter.all], 3);
      expect(counts[DocsFilter.markdown], 2);
      expect(counts[DocsFilter.pages], 1);
      expect(counts[DocsFilter.changed], 1);
    });

    // The whole point of D6: a chip must never be dead in a valid repo. A repo
    // with no `mockups/` directory (like `rho`) still has markdown and html
    // files, so the kind chips must count them off `DocInfo.kind`, never a path.
    test('kind chips are non-zero in a repo with no mockups/ directory', () {
      final snap = _snap([
        _doc('docs/spec.md', kind: DocKind.md),
        _doc('docs/board.html', kind: DocKind.html),
        _doc('NOTES.md', kind: DocKind.md),
      ]);
      final counts = docsFilterCounts(snap, repos);
      expect(counts[DocsFilter.markdown], 2);
      expect(counts[DocsFilter.pages], 1);
    });
  });

  group('recentDocs (D5)', () {
    test('keeps the 5 newest in scope, newest first', () {
      final docs = [
        for (var i = 0; i < 8; i++) _doc('n$i.md', modifiedAt: i * 10),
      ];
      final r = recentDocs(docs);
      expect(r, hasLength(5));
      expect(r.map((d) => d.relPath), [
        'n7.md',
        'n6.md',
        'n5.md',
        'n4.md',
        'n3.md',
      ]);
    });

    test('returns everything when fewer than the limit', () {
      final docs = [_doc('a.md', modifiedAt: 5), _doc('b.md', modifiedAt: 9)];
      expect(recentDocs(docs).map((d) => d.relPath), ['b.md', 'a.md']);
    });

    test('Recent excludes a newer doc outside the active project (D8)', () {
      // A doc in a foreign worktree is newer than everything in the active
      // project. The screen scopes with filterDocs(repoId) before Recent, so a
      // naive recentDocs over all docs cannot surface it.
      final snap = _snap([
        _doc('a1.md', worktreePath: '/repo/a', modifiedAt: 10, title: 'A1'),
        _doc('a2.md', worktreePath: '/repo/a', modifiedAt: 20, title: 'A2'),
        _doc(
          'other.md',
          worktreePath: '/elsewhere',
          modifiedAt: 999,
          title: 'Other',
        ),
      ]);
      final scoped = filterDocs(snap, DocsFilter.all, repos, repoId: 'r1');
      final recent = recentDocs(scoped);
      expect(recent.map((d) => d.relPath), ['a2.md', 'a1.md']);
      expect(recent.map((d) => d.title), isNot(contains('Other')));
    });
  });

  group('repoIdOwningNewestDoc (D4)', () {
    test('is the repo holding the doc with the largest mtime', () {
      final twoRepos = ReposState([
        const RepoInfo(
          id: 'alpha',
          name: 'alpha',
          path: '/alpha',
          pinned: false,
          lastActivityAt: 0,
          isGitRepo: true,
          defaultBranch: 'main',
          currentBranch: 'main',
          worktrees: [
            Worktree(
              id: 'wa',
              path: '/alpha/wt',
              branch: 'main',
              isPrimary: true,
              insertions: 0,
              deletions: 0,
              filesChanged: 0,
              sessionIds: [],
            ),
          ],
        ),
        const RepoInfo(
          id: 'beta',
          name: 'beta',
          path: '/beta',
          pinned: false,
          lastActivityAt: 0,
          isGitRepo: true,
          defaultBranch: 'main',
          currentBranch: 'main',
          worktrees: [
            Worktree(
              id: 'wb',
              path: '/beta/wt',
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
      final grouping = groupDocsByRepoWorktree([
        _doc('old.md', worktreePath: '/alpha/wt', modifiedAt: 10),
        _doc('new.md', worktreePath: '/beta/wt', modifiedAt: 99),
      ], twoRepos);
      expect(repoIdOwningNewestDoc(grouping), 'beta');
    });

    test('is null for an empty grouping', () {
      expect(repoIdOwningNewestDoc(const DocsGrouping(repos: [])), isNull);
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
        filterDocs(snap, DocsFilter.all, repos),
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
        filterDocs(snap, DocsFilter.all, repos),
        _repos(),
      );
      expect(grouping.repos, isEmpty);
    });
  });
}
