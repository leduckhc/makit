/// SPEC-45 D10 — a removed worktree takes its starter drafts with it.
///
/// The three starter key spaces (keyed `starter:` + a JSON `[projectId,
/// worktreePath]` pair — see `starterDraftKey`) are app-wide and NOT
/// `autoDispose`, which is what makes a draft survive a tab switch. The cost is
/// that nothing ever dropped them: a staged screenshot for a worktree that has
/// since been wrapped up held its bytes for the life of the process.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/desktop_session_prune.dart';
import 'package:makit/desktop/chat/starter_picks.dart';
import 'package:makit/desktop/chat/starter_prune.dart';
import 'package:makit/store/composer_attachments.dart';
import 'package:makit/store/media.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/transport/media_client.dart';
import 'package:makit/ui/composer/composer_draft.dart';

const _gone = '/tmp/wt-gone';
const _kept = '/tmp/wt-kept';

/// A repos snapshot the wiring test can push new values into, so the prune runs
/// through `desktopSessionPruneProvider`'s own listener rather than being called.
final _reposFeed = StateProvider<ReposState>(
  (ref) => ReposState([
    _repo(const [_gone, _kept]),
  ]),
);

/// The prune takes a `Ref` (production calls it from
/// `desktopSessionPruneProvider`), so drive it through a throwaway provider that
/// hands back a callback: writing to other providers *during* a build is a
/// Riverpod assertion, which is why production defers this to `afterPass`.
final _pruner = Provider<void Function()>(
  (ref) =>
      () => pruneStarterDrafts(ref, ref.read(reposProvider)),
);

RepoInfo _repo(List<String> paths, {String id = 'p1'}) => RepoInfo(
  id: id,
  name: id,
  path: '/tmp/$id',
  pinned: false,
  lastActivityAt: 0,
  isGitRepo: true,
  defaultBranch: 'main',
  currentBranch: 'main',
  worktrees: [
    for (final p in paths)
      Worktree(
        id: p,
        path: p,
        branch: p.split('/').last,
        isPrimary: false,
        insertions: 0,
        deletions: 0,
        filesChanged: 0,
        sessionIds: const [],
      ),
  ],
);

/// Seeds all three key spaces for both worktrees, plus a live-session draft that
/// must never be touched by a worktree-scoped prune.
Future<ProviderContainer> _seeded({required ReposState repos}) async {
  final container = ProviderContainer(
    overrides: [
      reposProvider.overrideWithValue(repos),
      mediaUploaderProvider.overrideWithValue(
        (Uint8List bytes, String mime) async =>
            MediaDescriptor(mediaId: 'a' * 64, mime: mime, sizeBytes: 3),
      ),
    ],
  );
  addTearDown(container.dispose);
  final drafts = container.read(composerDraftsProvider.notifier);
  final picks = container.read(starterPicksProvider.notifier);
  final atts = container.read(composerAttachmentsProvider.notifier);
  for (final path in [_gone, _kept]) {
    drafts.set(starterDraftKey('p1', path), 'half typed in $path');
    picks.chooseAgent(starterDraftKey('p1', path), 'codex');
    await atts.add(
      key: starterDraftKey('p1', path),
      localId: 'l-$path',
      bytes: Uint8List.fromList([1, 2, 3]),
      mime: 'image/png',
      name: 'shot.png',
    );
  }
  drafts.set('s1', 'a live session draft');
  return container;
}

void main() {
  testWidgets('a vanished worktree drops its draft, picks and images', (
    tester,
  ) async {
    final container = await _seeded(
      repos: ReposState([
        _repo(const [_kept]),
      ]),
    );

    container.read(_pruner)();

    expect(
      container.read(composerDraftsProvider)[starterDraftKey('p1', _gone)],
      isNull,
    );
    expect(
      container.read(starterPicksProvider)[starterDraftKey('p1', _gone)],
      isNull,
    );
    expect(
      container.read(composerAttachmentsProvider)[starterDraftKey('p1', _gone)],
      isNull,
    );
  });

  testWidgets('a worktree that is still listed keeps everything', (
    tester,
  ) async {
    final container = await _seeded(
      repos: ReposState([
        _repo(const [_kept]),
      ]),
    );

    container.read(_pruner)();

    expect(
      container.read(composerDraftsProvider)[starterDraftKey('p1', _kept)],
      'half typed in $_kept',
    );
    expect(
      container.read(starterPicksProvider)[starterDraftKey('p1', _kept)],
      isNotNull,
    );
    expect(
      container.read(composerAttachmentsProvider)[starterDraftKey('p1', _kept)],
      hasLength(1),
    );
  });

  testWidgets('a live session draft is never touched', (tester) async {
    final container = await _seeded(
      repos: ReposState([
        _repo(const [_kept]),
      ]),
    );

    container.read(_pruner)();

    expect(
      container.read(composerDraftsProvider)['s1'],
      'a live session draft',
    );
  });

  testWidgets('an unloaded repo list prunes nothing', (tester) async {
    // Before the first snapshot, "no repos" means "we do not know yet". Pruning
    // then would wipe the draft of every worktree the user has.
    final container = await _seeded(repos: ReposState(const []));

    container.read(_pruner)();

    expect(
      container.read(composerDraftsProvider)[starterDraftKey('p1', _gone)],
      isNotNull,
    );
  });

  testWidgets('the owning repo mid-refresh (empty worktrees) prunes nothing', (
    tester,
  ) async {
    // `closeGroupsForDeletedWorktrees` guards the same way: a repo can report an
    // empty worktree list while refreshing, which is not evidence of removal.
    final container = await _seeded(repos: ReposState([_repo(const [])]));

    container.read(_pruner)();

    expect(
      container.read(composerDraftsProvider)[starterDraftKey('p1', _gone)],
      isNotNull,
    );
  });

  testWidgets('an unrelated non-git project does not block the prune', (
    tester,
  ) async {
    // A non-git project legitimately reports NO worktrees (`repo_service.ts`
    // hands back `[]` when `isGitRepo` is false). Bailing on "any repo looks
    // unpopulated" therefore disabled pruning for everyone who has one — the
    // guard has to be per-repo, like its sibling's.
    final container = await _seeded(
      repos: ReposState([
        _repo(const [_kept]),
        _repo(const [], id: 'notes'),
      ]),
    );

    container.read(_pruner)();

    expect(
      container.read(composerDraftsProvider)[starterDraftKey('p1', _gone)],
      isNull,
    );
    expect(
      container.read(composerDraftsProvider)[starterDraftKey('p1', _kept)],
      isNotNull,
    );
  });

  testWidgets('a key whose project is not in the snapshot is left alone', (
    tester,
  ) async {
    // Not "gone" — unknown. The snapshot cannot speak for a project it does not
    // contain, so saying nothing is the only honest answer.
    final container = await _seeded(
      repos: ReposState([
        _repo(const [_kept], id: 'other-project'),
      ]),
    );

    container.read(_pruner)();

    expect(
      container.read(composerDraftsProvider)[starterDraftKey('p1', _gone)],
      isNotNull,
    );
  });

  // Ids are `randomUUID()` today, but the loader accepts any persisted string
  // (`project-store.ts` only checks `typeof id === "string"`), so a key that is
  // not parsed losslessly can name the WRONG project — and this function deletes
  // typed text and staged image bytes. Each id below broke a previous key format:
  // `a:b` broke the `:` separator (read back as project `a` with a path `a` does
  // not list), `a\u0000b` broke the `\u0000` separator the same way. Both must now
  // survive a prune in which the decoy project is present and populated.
  for (final (name, hostileId) in const [
    ('a colon', 'a:b'),
    ('a NUL', 'a\u0000b'),
  ]) {
    testWidgets('a project id containing $name cannot eat another\'s draft', (
      tester,
    ) async {
      final decoy = hostileId.split(RegExp(r'[:\u0000]')).first; // 'a'
      final container = ProviderContainer(
        overrides: [
          reposProvider.overrideWithValue(
            ReposState([
              _repo(const ['/other'], id: decoy),
              _repo(const ['/wt'], id: hostileId),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);
      final key = starterDraftKey(hostileId, '/wt');
      container.read(composerDraftsProvider.notifier).set(key, 'still wanted');

      container.read(_pruner)();

      expect(container.read(composerDraftsProvider)[key], 'still wanted');
    });
  }

  testWidgets('the prune is wired to the repos snapshot, not just callable', (
    tester,
  ) async {
    // Every other test here calls `pruneStarterDrafts` directly, so they would
    // all still pass with both production call sites deleted. This one goes
    // through `desktopSessionPruneProvider` and its `afterPass` microtask.
    final container = ProviderContainer(
      overrides: [
        reposProvider.overrideWith((ref) => ref.watch(_reposFeed)),
        sessionsProvider.overrideWithValue(SessionsState(const [])),
      ],
    );
    addTearDown(container.dispose);
    final key = starterDraftKey('p1', _gone);
    container.read(composerDraftsProvider.notifier).set(key, 'typed here');
    // `listen`, not `read`: the provider (and therefore its repos listener) is
    // only alive while something subscribes to it — `desktop_session_prune_test`
    // documents the same requirement, mirroring the widget-level `ref.watch`.
    container.listen(
      desktopSessionPruneProvider,
      (_, _) {},
      fireImmediately: true,
    );
    await tester.pump();

    // The worktree is removed (wrap up / discard), so the next snapshot drops it.
    container.read(_reposFeed.notifier).state = ReposState([
      _repo(const [_kept]),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(container.read(composerDraftsProvider)[key], isNull);
  });

  testWidgets('a draft already stale at activation is pruned', (tester) async {
    // The listener test above only covers the repos-listener call site; the
    // `afterPass` on provider activation is what handles the common case of a
    // worktree removed while the app was closed, so it needs its own case.
    final container = ProviderContainer(
      overrides: [
        reposProvider.overrideWithValue(
          ReposState([
            _repo(const [_kept]),
          ]),
        ),
        sessionsProvider.overrideWithValue(SessionsState(const [])),
      ],
    );
    addTearDown(container.dispose);
    final key = starterDraftKey('p1', _gone);
    container.read(composerDraftsProvider.notifier).set(key, 'typed last week');

    container.listen(
      desktopSessionPruneProvider,
      (_, _) {},
      fireImmediately: true,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(container.read(composerDraftsProvider)[key], isNull);
  });

  group('the starter key codec is total', () {
    // Third review, third key format. The first two (`:` then `\u0000`) each
    // assumed a character could not appear in a component, and each assumption
    // was wrong for some input the project store will accept — so the codec is
    // now self-describing rather than delimiter-based, and this group is the
    // proof rather than an argument about which byte is safe.
    for (final (name, projectId, path) in const [
      ('plain', 'p1', '/tmp/wt'),
      (
        'uuid + linked worktree',
        'f81d4fae-7dec-11d0-a765-00a0c91e6bf6',
        '/Users/le/.worktrees/makit/feat-x',
      ),
      ('colon in both halves', 'a:b', '/tmp/od:d'),
      ('NUL in the id', 'a\u0000b', '/wt'),
      ('NUL in the path', 'p1', '/w\u0000t'),
      ('empty id', '', '/tmp/wt'),
      ('empty path', 'p1', ''),
      ('both empty', '', ''),
      ('the prefix itself as an id', 'starter:', '/tmp/wt'),
      ('json metacharacters', '"]},{[', '/tmp/"quoted"/\\path'),
      ('newline and emoji', 'a\nb\u{1F600}', '/tmp/\u{1F600}'),
    ]) {
      test(name, () {
        final parsed = parseStarterKey(starterDraftKey(projectId, path));
        expect(parsed, isNotNull, reason: 'must round-trip');
        expect(parsed!.projectId, projectId);
        expect(parsed.path, path);
      });
    }

    test('a live session id is not mistaken for a starter key', () {
      // Session ids are ULIDs, but the check must not depend on that: anything
      // that is not a key this builder produced has to read back as null, or the
      // prune would treat a live session's draft as a dead worktree's.
      for (final notAKey in const [
        '01JQ8ZK7NP2T6VYB3S9A4C5D6E',
        'starter:',
        'starter:not-json',
        'starter:[]',
        'starter:["only-one"]',
        'starter:["a","b","c"]',
        'starter:{"projectId":"a","path":"b"}',
        'starter:[1,2]',
        '',
      ]) {
        expect(parseStarterKey(notAKey), isNull, reason: notAKey);
      }
    });
  });
}
