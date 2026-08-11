// SPEC-51 — the sidebar worktree row under preview groups: a single click opens
// the branch as the disposable (preview) group, a double click keeps it.
//
// Mounts the real `DesktopSidebar` (the row widget is private) in a plain
// `MaterialApp(home: …)`, matching `desktop_sidebar_ports_menu_test.dart`: that
// is what the desktop shell is.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/desktop_sidebar.dart';
import 'package:makit/desktop/chat/groups/groups_controller.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/ports.dart';
import 'package:makit/store/prefs/preference_entries.dart';
import 'package:makit/store/prefs/preferences_controller.dart';
import 'package:makit/store/prefs/preferences_providers.dart';
import 'package:makit/store/store.dart';

Worktree _wt(String path, String branch) => Worktree(
  id: path,
  path: path,
  branch: branch,
  isPrimary: false,
  insertions: 0,
  deletions: 0,
  filesChanged: 0,
  sessionIds: const [],
);

RepoInfo _repo(List<Worktree> worktrees) => RepoInfo(
  id: 'r1',
  name: 'makit',
  path: '/r1',
  pinned: false,
  lastActivityAt: 0,
  isGitRepo: true,
  defaultBranch: 'main',
  currentBranch: 'main',
  worktrees: worktrees,
);

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required bool preview,
}) async {
  final container = ProviderContainer(
    overrides: [
      reposProvider.overrideWithValue(
        ReposState([
          _repo([_wt('/wt/a', 'feat/a'), _wt('/wt/b', 'feat/b')]),
        ]),
      ),
      sessionsProvider.overrideWithValue(SessionsState(const [])),
      portsProvider.overrideWithValue(
        const PortsSnapshot(ports: [], scannedAt: 0, scanOk: true),
      ),
      portsWatchProvider.overrideWithValue(PortsWatch((_) {})),
      preferencesControllerProvider.overrideWith(
        (ref) =>
            PreferencesController(null, {previewGroupsPreference.id: preview}),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: SizedBox(width: 320, child: DesktopSidebar())),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('a single click opens the branch as the preview group', (
    tester,
  ) async {
    final container = await _pump(tester, preview: true);

    await tester.tap(find.text('feat/a'));
    await tester.pumpAndSettle();

    final groups = container.read(groupsControllerProvider);
    expect(groups.previewGroup?.worktreePath, '/wt/a');
  });

  testWidgets('a single click activates without any double-tap wait', (
    tester,
  ) async {
    // A regression guard with history: wiring promotion to `InkWell.onDoubleTap`
    // put a double-tap recognizer in the arena, which defers `onTap` until the
    // double-tap timer expires — every branch click gained ~300ms of lag, and
    // this test caught it. One `pump()` with no elapsed time must be enough.
    final container = await _pump(tester, preview: true);

    await tester.tap(find.text('feat/a'));
    await tester.pump();

    expect(
      container.read(groupsControllerProvider).previewGroup?.worktreePath,
      '/wt/a',
      reason: 'the row must not defer its tap to a double-tap timer',
    );
  });

  testWidgets('clicking the branch you are previewing keeps it (decision 4)', (
    tester,
  ) async {
    final container = await _pump(tester, preview: true);

    await tester.tap(find.text('feat/a'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('feat/a'));
    await tester.pumpAndSettle();

    final groups = container.read(groupsControllerProvider);
    expect(groups.previewGroupId, isNull, reason: 'promoted by the 2nd click');
    expect(
      groups.groups.where((g) => g.worktreePath == '/wt/a'),
      hasLength(1),
      reason: 'the same group, kept — not a second one',
    );
  });

  testWidgets('a slow second click keeps it too (no timing window)', (
    tester,
  ) async {
    final container = await _pump(tester, preview: true);

    await tester.tap(find.text('feat/a'));
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.text('feat/a'));
    await tester.pumpAndSettle();

    expect(container.read(groupsControllerProvider).previewGroupId, isNull);
  });

  testWidgets('clicking a background preview group is still navigation', (
    tester,
  ) async {
    // Decision 9: only a repeat click on what is *on screen* promotes. Coming
    // back to a preview group from elsewhere is navigation, so it stays
    // disposable.
    final container = await _pump(tester, preview: true);

    await tester.tap(find.text('feat/a'));
    await tester.pumpAndSettle();
    final previewId = container.read(groupsControllerProvider).previewGroupId;
    container.read(groupsControllerProvider.notifier).newBoard();
    await tester.pumpAndSettle();

    await tester.tap(find.text('feat/a'));
    await tester.pumpAndSettle();

    final groups = container.read(groupsControllerProvider);
    expect(groups.previewGroupId, previewId, reason: 'still disposable');
    expect(groups.activeGroupId, previewId);
  });

  testWidgets('browsing two branches leaves one worktree group', (
    tester,
  ) async {
    final container = await _pump(tester, preview: true);

    await tester.tap(find.text('feat/a'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('feat/b'));
    await tester.pumpAndSettle();

    final worktreeGroups = container
        .read(groupsControllerProvider)
        .groups
        .where((g) => g.worktreePath != null);
    expect(worktreeGroups, hasLength(1));
    expect(worktreeGroups.single.worktreePath, '/wt/b');
  });

  testWidgets('with the pref off, browsing accumulates as before', (
    tester,
  ) async {
    final container = await _pump(tester, preview: false);

    await tester.tap(find.text('feat/a'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('feat/b'));
    await tester.pumpAndSettle();

    final state = container.read(groupsControllerProvider);
    expect(state.groups.where((g) => g.worktreePath != null), hasLength(2));
    expect(state.previewGroupId, isNull);
  });
}
