/// SPEC-45 D10 — a removed worktree takes its starter drafts with it.
///
/// The three starter key spaces (`starter:<worktreePath>`) are app-wide and NOT
/// `autoDispose`, which is what makes a draft survive a tab switch. The cost is
/// that nothing ever dropped them: a staged screenshot for a worktree that has
/// since been wrapped up held its bytes for the life of the process.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
    drafts.set('starter:p1:$path', 'half typed in $path');
    picks.chooseAgent('starter:p1:$path', 'codex');
    await atts.add(
      key: 'starter:p1:$path',
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

    expect(container.read(composerDraftsProvider)['starter:p1:$_gone'], isNull);
    expect(container.read(starterPicksProvider)['starter:p1:$_gone'], isNull);
    expect(
      container.read(composerAttachmentsProvider)['starter:p1:$_gone'],
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
      container.read(composerDraftsProvider)['starter:p1:$_kept'],
      'half typed in $_kept',
    );
    expect(
      container.read(starterPicksProvider)['starter:p1:$_kept'],
      isNotNull,
    );
    expect(
      container.read(composerAttachmentsProvider)['starter:p1:$_kept'],
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
      container.read(composerDraftsProvider)['starter:p1:$_gone'],
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
      container.read(composerDraftsProvider)['starter:p1:$_gone'],
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

    expect(container.read(composerDraftsProvider)['starter:p1:$_gone'], isNull);
    expect(
      container.read(composerDraftsProvider)['starter:p1:$_kept'],
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
      container.read(composerDraftsProvider)['starter:p1:$_gone'],
      isNotNull,
    );
  });
}
