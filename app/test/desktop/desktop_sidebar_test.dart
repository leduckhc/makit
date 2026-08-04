import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/desktop/chat/desktop_sidebar.dart';
import 'package:makit/desktop/chat/groups/group.dart';
import 'package:makit/desktop/chat/groups/groups_controller.dart';
import 'package:makit/desktop/chat/panes/workspace_controller.dart';
import 'package:makit/desktop/chat/selected_session.dart';
import 'package:makit/desktop/chat/sidebar_layout.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/transport/ws_client.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/home/repo_chips.dart';
import 'package:makit/ui/widgets/pr_state_style.dart';

import '../support/svg_asset_finder.dart';

/// In-memory secure storage so ConnectionController (which StoreController
/// subscribes to in its constructor) boots without platform channels.
class _EmptyStorage implements SecureStore {
  const _EmptyStorage();
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String? value}) async {}
  @override
  Future<void> delete({required String key}) async {}
}

/// A StoreController that records the mutating commands the sidebar issues,
/// so tests can assert the action menus actually invoke them (and can force a
/// failure to exercise the error-snackbar paths).
class _FakeStore extends StoreController {
  _FakeStore(super.ref);

  final List<String> hidden = [];
  final List<String> removedWorktrees = [];
  final List<({String path, String name})> renames = [];
  final List<String> spawned = [];
  bool fail = false;

  @override
  Future<String> spawnSession(
    String projectId, {
    String? title,
    String? agent,
    String? worktreePath,
    String? branch,
    List<ConfigOptionPick>? configOptions,
  }) async {
    spawned.add(projectId);
    if (fail) throw Exception('nope');
    return 'draft-$projectId';
  }

  @override
  Future<void> removeProject(String id) async {
    hidden.add(id);
    if (fail) throw Exception('nope');
  }

  @override
  Future<void> removeWorktree(String projectId, String worktreePath) async {
    removedWorktrees.add(worktreePath);
    if (fail) throw Exception('nope');
  }

  @override
  Future<void> renameBranch(
    String projectId,
    String worktreePath,
    String newName,
  ) async {
    renames.add((path: worktreePath, name: newName));
    if (fail) throw Exception('nope');
  }
}

RepoInfo _repo(
  String id,
  String name, {
  String? currentBranch,
  String? defaultBranch,
  List<Worktree> worktrees = const [],
}) => RepoInfo(
  id: id,
  name: name,
  path: '/tmp/$id',
  pinned: false,
  lastActivityAt: 0,
  isGitRepo: true,
  defaultBranch: defaultBranch ?? 'main',
  currentBranch: currentBranch ?? 'main',
  worktrees: worktrees,
);

Worktree _worktree(
  String id, {
  String? branch,
  bool isPrimary = false,
  int insertions = 0,
  int deletions = 0,
  int filesChanged = 0,
  List<String> sessionIds = const [],
  PullRequest? pr,
}) => Worktree(
  id: id,
  path: '/tmp/wt/$id',
  branch: branch,
  isPrimary: isPrimary,
  insertions: insertions,
  deletions: deletions,
  filesChanged: filesChanged,
  sessionIds: sessionIds,
  pr: pr,
);

Session _session(
  String id,
  String projectId,
  String title,
  String agent, {
  bool pending = false,
  SessionStatus status = SessionStatus.idle,
  String lastPreview = '',
  bool resumable = false,
}) => Session(
  id: id,
  projectId: projectId,
  agent: agent,
  title: title,
  status: status,
  policy: ApprovalPolicy.askOnRisky,
  pending: pending,
  lastPreview: lastPreview,
  resumable: resumable,
);

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required List<RepoInfo> repos,
  required List<Session> sessions,
}) async {
  final container = ProviderContainer(
    overrides: [
      reposProvider.overrideWithValue(ReposState(repos)),
      sessionsProvider.overrideWithValue(SessionsState(sessions)),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: SizedBox(width: 320, child: DesktopSidebar())),
      ),
    ),
  );
  return container;
}

/// Like [_pump] but with a recording [_FakeStore] so tests can invoke the
/// action menus and assert the commands they issue.
Future<_FakeStore> _pumpWithStore(
  WidgetTester tester, {
  required List<RepoInfo> repos,
  required List<Session> sessions,
  bool fail = false,
}) async {
  late _FakeStore store;
  final container = ProviderContainer(
    overrides: [
      reposProvider.overrideWithValue(ReposState(repos)),
      sessionsProvider.overrideWithValue(SessionsState(sessions)),
      connectionControllerProvider.overrideWith(
        (ref) => ConnectionController(const _EmptyStorage()),
      ),
      storeControllerProvider.overrideWith((ref) {
        store = _FakeStore(ref)..fail = fail;
        return store;
      }),
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
  // Materialize the overridden store provider.
  container.read(storeControllerProvider.notifier);
  return store;
}

/// Hover a worktree row and open its actions menu. Removes its pointer before
/// returning so it can be called again in the same test (the open menu stays
/// mounted via `_menuOpen`).
Future<void> _openWorktreeMenu(WidgetTester tester, String branchLabel) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  await gesture.moveTo(tester.getCenter(find.text(branchLabel)));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Worktree actions'));
  await tester.pumpAndSettle();
  await gesture.removePointer();
  await tester.pumpAndSettle();
}

/// Hover the repo header row and open its (hover-only) actions menu. Removes
/// its pointer before returning so the [Visibility]-gated button state is
/// clean for later interactions in the same test.
Future<void> _openRepoMenu(WidgetTester tester, String repoName) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  await gesture.moveTo(tester.getCenter(find.text(repoName)));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Repo actions'));
  await tester.pumpAndSettle();
  await gesture.removePointer();
  await tester.pumpAndSettle();
}

/// Hover the repo header row and tap its (hover-only) `+` new-worktree button.
Future<void> _tapNewWorktree(WidgetTester tester, String repoName) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  await gesture.moveTo(tester.getCenter(find.text(repoName)));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('New worktree'));
  await tester.pumpAndSettle();
  await gesture.removePointer();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('sidebar groups sessions by repo → worktree', (tester) async {
    await _pump(
      tester,
      repos: [
        _repo(
          'p1',
          'alpha',
          worktrees: [
            _worktree('wt-main', branch: 'main', isPrimary: true),
            _worktree(
              'wt-feat',
              branch: 'feat/login',
              insertions: 12,
              deletions: 3,
              sessionIds: ['s1'],
            ),
          ],
        ),
      ],
      sessions: [_session('s1', 'p1', 'Fix login bug', 'codex')],
    );

    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('feat/login'), findsOneWidget);
    expect(find.text('Fix login bug'), findsOneWidget);
    // Only the worktree diff chip now (the repo-rollup aggregate was removed).
    expect(find.text('+12'), findsOneWidget);
    expect(find.text('−3'), findsOneWidget);
  });

  testWidgets('tapping a session selects it', (tester) async {
    final container = await _pump(
      tester,
      repos: [
        _repo(
          'p1',
          'alpha',
          worktrees: [
            _worktree(
              'wt-main',
              branch: 'main',
              isPrimary: true,
              sessionIds: ['s1'],
            ),
          ],
        ),
      ],
      sessions: [_session('s1', 'p1', 'Fix login bug', 'codex')],
    );

    expect(container.read(selectedSessionProvider), isNull);

    await tester.tap(find.text('Fix login bug'));
    await tester.pump();

    expect(container.read(selectedSessionProvider), 's1');
  });

  testWidgets('a pending session renders under its worktree row', (
    tester,
  ) async {
    await _pump(
      tester,
      repos: [
        _repo(
          'p1',
          'alpha',
          worktrees: [
            _worktree(
              'wt-main',
              branch: 'main',
              isPrimary: true,
              sessionIds: ['s1'],
            ),
          ],
        ),
      ],
      sessions: [_session('s1', 'p1', 'Fix login bug', 'pi', pending: true)],
    );

    // Its worktree is known at spawn time, so there is no separate draft row.
    expect(find.text('DRAFTS'), findsNothing);
    expect(find.text('new worktree'), findsNothing);
    expect(find.text('Fix login bug'), findsOneWidget);
  });

  testWidgets('open PR renders a PR pill on its worktree row', (tester) async {
    await _pump(
      tester,
      repos: [
        _repo(
          'p1',
          'alpha',
          worktrees: [
            _worktree('wt-main', branch: 'main', isPrimary: true),
            _worktree(
              'wt-feat',
              branch: 'feat/x',
              insertions: 1,
              sessionIds: ['s1'],
              pr: const PullRequest(
                number: 42,
                url: '',
                state: 'OPEN',
                title: 'x',
                isDraft: false,
              ),
            ),
          ],
        ),
      ],
      sessions: [_session('s1', 'p1', 'work', 'pi')],
    );

    expect(find.text('PR #42'), findsOneWidget);
  });

  testWidgets('worktree icon reflects the PR state', (tester) async {
    await _pump(
      tester,
      repos: [
        _repo(
          'p1',
          'alpha',
          worktrees: [
            _worktree('wt-plain', branch: 'feat/no-pr', sessionIds: ['s1']),
            _worktree(
              'wt-pr',
              branch: 'feat/has-pr',
              sessionIds: ['s2'],
              pr: const PullRequest(
                number: 7,
                url: '',
                state: 'OPEN',
                title: 'x',
                isDraft: false,
              ),
            ),
            _worktree(
              'wt-merged-pr',
              branch: 'feat/merged-pr',
              sessionIds: ['s3'],
              pr: const PullRequest(
                number: 8,
                url: '',
                state: 'MERGED',
                title: 'y',
                isDraft: false,
              ),
            ),
            _worktree(
              'wt-closed-pr',
              branch: 'feat/closed-pr',
              sessionIds: ['s4'],
              pr: const PullRequest(
                number: 9,
                url: '',
                state: 'CLOSED',
                title: 'z',
                isDraft: false,
              ),
            ),
          ],
        ),
      ],
      sessions: [
        _session('s1', 'p1', 'a', 'pi'),
        _session('s2', 'p1', 'b', 'pi'),
        _session('s3', 'p1', 'c', 'pi'),
        _session('s4', 'p1', 'd', 'pi'),
      ],
    );

    // Open PRs show the PR symbol, merged PRs a purple merge marker, closed PRs
    // the dedicated closed-PR marker; only PR-less worktrees retain the plain
    // branch icon.
    expect(find.byIcon(PhosphorIconsLight.gitPullRequest), findsOneWidget);
    expect(find.byIcon(PhosphorIconsLight.gitMerge), findsOneWidget);
    expect(findSvgAsset(kClosedPrAsset), findsOneWidget);
    expect(find.byIcon(PhosphorIconsLight.gitBranch), findsOneWidget);
    expect(
      tester.widget<Icon>(find.byIcon(PhosphorIconsLight.gitMerge)).color,
      kPrMerged,
    );
  });

  testWidgets('empty state prompts to start a session', (tester) async {
    await _pump(tester, repos: const [], sessions: const []);
    expect(find.textContaining('No repos yet'), findsOneWidget);
  });

  testWidgets('the caret collapses a worktree row; the row itself does not', (
    tester,
  ) async {
    await _pump(
      tester,
      repos: [
        _repo(
          'p1',
          'alpha',
          worktrees: [
            _worktree('wt-feat', branch: 'feat/login', sessionIds: ['s1']),
          ],
        ),
      ],
      sessions: [_session('s1', 'p1', 'Fix login bug', 'codex')],
    );

    expect(find.text('Fix login bug'), findsOneWidget);

    // Tapping the row activates the group (decision 15) and must NOT collapse:
    // peeking at a branch's children should not require giving up the canvas,
    // and moving the canvas should not require collapsing the row.
    await tester.tap(find.text('feat/login'));
    await tester.pumpAndSettle();
    expect(
      find.text('Fix login bug'),
      findsOneWidget,
      reason: 'the row activates; it does not toggle',
    );

    // The caret is the disclosure control.
    await tester.tap(find.byKey(const Key('worktreeCaret-/tmp/wt/wt-feat')));
    await tester.pumpAndSettle();
    expect(find.text('Fix login bug'), findsNothing);

    await tester.tap(find.byKey(const Key('worktreeCaret-/tmp/wt/wt-feat')));
    await tester.pumpAndSettle();
    expect(find.text('Fix login bug'), findsOneWidget);
  });

  testWidgets('repo names are sentence-case and bold, not upper-cased', (
    tester,
  ) async {
    await _pump(
      tester,
      repos: [
        _repo('p1', 'makit', worktrees: [_worktree('wt-main')]),
      ],
      sessions: const [],
    );

    expect(find.text('makit'), findsOneWidget);
    expect(find.text('MAKIT'), findsNothing);
    final label = tester.widget<Text>(find.text('makit'));
    expect(label.style?.fontWeight, FontWeight.w700);
    expect(
      label.style?.letterSpacing ?? 0,
      0,
      reason: 'tracking belongs to upper-cased labels, which this is not',
    );
  });

  testWidgets('session rows are xs text in a tight container', (tester) async {
    await _pump(
      tester,
      repos: [
        _repo(
          'p1',
          'alpha',
          worktrees: [
            _worktree('wt-a', branch: 'a', sessionIds: ['s1']),
          ],
        ),
      ],
      sessions: [_session('s1', 'p1', 'Fix login bug', 'codex')],
    );

    final label = tester.widget<Text>(find.text('Fix login bug'));
    expect(label.style?.fontSize, 10);
    // The row was a dense ListTile (~40px); a 10px label does not need that.
    expect(
      tester
          .getSize(
            find.ancestor(
              of: find.text('Fix login bug'),
              matching: find.byType(ListTile),
            ),
          )
          .height,
      lessThanOrEqualTo(28),
    );
  });

  testWidgets('branch names align whether or not the row has a caret', (
    tester,
  ) async {
    // Only rows with something to disclose get a caret, so the caret-less rows
    // reserve its width instead — otherwise branch names would stagger down the
    // column. Measured, because this is invisible until it is wrong.
    await _pump(
      tester,
      repos: [
        _repo(
          'p1',
          'alpha',
          worktrees: [
            _worktree('wt-a', branch: 'no-sessions'),
            _worktree('wt-b', branch: 'has-sessions', sessionIds: ['s1']),
          ],
        ),
      ],
      sessions: [_session('s1', 'p1', 'Something', 'codex')],
    );

    expect(
      tester.getTopLeft(find.text('no-sessions')).dx,
      tester.getTopLeft(find.text('has-sessions')).dx,
    );
  });

  testWidgets('tapping the repo header folds/unfolds its worktrees', (
    tester,
  ) async {
    await _pump(
      tester,
      repos: [
        _repo(
          'p1',
          'alpha',
          worktrees: [
            _worktree('wt-feat', branch: 'feat/login', sessionIds: ['s1']),
          ],
        ),
      ],
      sessions: [_session('s1', 'p1', 'Fix login bug', 'codex')],
    );

    // Worktree is visible by default (repo group starts expanded).
    expect(find.text('feat/login'), findsOneWidget);

    // Tapping the repo name row collapses the whole group.
    await tester.tap(find.text('alpha'));
    await tester.pumpAndSettle();
    expect(find.text('feat/login'), findsNothing);

    // Tapping again re-expands it.
    await tester.tap(find.text('alpha'));
    await tester.pumpAndSettle();
    expect(find.text('feat/login'), findsOneWidget);
  });

  testWidgets('repo header overflow menu lists only Hide', (tester) async {
    await _pump(
      tester,
      repos: [
        _repo(
          'p1',
          'alpha',
          worktrees: [_worktree('wt-main', branch: 'main', isPrimary: true)],
        ),
      ],
      sessions: const [],
    );

    // Repo actions surface only on hover, so move the pointer over the header.
    await _openRepoMenu(tester, 'alpha');
    expect(find.text('Hide the repo'), findsOneWidget);
    // The new-worktree picker moved to the + button: one door, not two.
    expect(find.text('New worktree from…'), findsNothing);
  });

  testWidgets('the + button opens the New worktree dialog (no bare spawn)', (
    tester,
  ) async {
    final store = await _pumpWithStore(
      tester,
      repos: [
        _repo(
          'p1',
          'alpha',
          worktrees: [_worktree('wt-main', branch: 'main', isPrimary: true)],
        ),
      ],
      sessions: const [],
    );

    await _tapNewWorktree(tester, 'alpha');

    // The dialog creates the worktree first; nothing spawns.
    expect(find.text('New worktree'), findsWidgets);
    expect(store.spawned, isEmpty);
  });

  testWidgets(
    'the repo actions button is present but inert (ignores taps) until '
    'the header row is hovered',
    (tester) async {
      await _pump(
        tester,
        repos: [
          _repo(
            'p1',
            'alpha',
            worktrees: [_worktree('wt-main', branch: 'main', isPrimary: true)],
          ),
        ],
        sessions: const [],
      );

      // maintainState keeps the button mounted (findable) even while hidden,
      // but it must not be interactive: tapping it without hovering first
      // must not open the menu.
      expect(find.byTooltip('Repo actions'), findsOneWidget);
      await tester.tap(find.byTooltip('Repo actions'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Hide the repo'), findsNothing);

      // Hovering first makes it interactive.
      await _openRepoMenu(tester, 'alpha');
      expect(find.text('Hide the repo'), findsOneWidget);
    },
  );

  testWidgets(
    'hovering a worktree hides the diff pill and shows the actions menu',
    (tester) async {
      await _pump(
        tester,
        repos: [
          _repo(
            'p1',
            'alpha',
            worktrees: [
              _worktree(
                'wt-feat',
                branch: 'feat/login',
                insertions: 12,
                deletions: 3,
                sessionIds: ['s1'],
              ),
            ],
          ),
        ],
        sessions: [_session('s1', 'p1', 'Fix login bug', 'codex')],
      );

      // Off-hover: the diff pill is visible, no actions menu.
      expect(find.text('+12'), findsOneWidget);
      expect(find.byTooltip('Worktree actions'), findsNothing);

      // Hover over the branch row.
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.text('feat/login')));
      await tester.pumpAndSettle();

      // On-hover: the diff pill is replaced by the actions menu.
      expect(find.text('+12'), findsNothing);
      expect(find.byTooltip('Worktree actions'), findsOneWidget);

      // Opening the menu lists both actions.
      await tester.tap(find.byTooltip('Worktree actions'));
      await tester.pumpAndSettle();
      expect(find.text('Rename branch'), findsOneWidget);
      expect(find.text('Delete worktree'), findsOneWidget);
    },
  );

  testWidgets('Rename branch is disabled on a worktree with an open PR', (
    tester,
  ) async {
    await _pump(
      tester,
      repos: [
        _repo(
          'p1',
          'alpha',
          worktrees: [
            _worktree(
              'wt-pr',
              branch: 'feat/has-pr',
              sessionIds: ['s1'],
              pr: const PullRequest(
                number: 7,
                url: '',
                state: 'OPEN',
                title: 'x',
                isDraft: false,
              ),
            ),
          ],
        ),
      ],
      sessions: [_session('s1', 'p1', 'work', 'pi')],
    );

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('feat/has-pr')));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Worktree actions'));
    await tester.pumpAndSettle();

    // The disabled 'Rename branch' item renders but its PopupMenuItem is
    // disabled (onTap null).
    final item = tester.widget<PopupMenuItem<String>>(
      find.widgetWithText(PopupMenuItem<String>, 'Rename branch'),
    );
    expect(item.enabled, isFalse);
  });

  testWidgets('primary worktree disables both Rename and Delete', (
    tester,
  ) async {
    await _pump(
      tester,
      repos: [
        _repo(
          'p1',
          'alpha',
          worktrees: [_worktree('wt-main', branch: 'main', isPrimary: true)],
        ),
      ],
      sessions: const [],
    );

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('main')));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Worktree actions'));
    await tester.pumpAndSettle();

    final rename = tester.widget<PopupMenuItem<String>>(
      find.widgetWithText(PopupMenuItem<String>, 'Rename branch'),
    );
    final delete = tester.widget<PopupMenuItem<String>>(
      find.widgetWithText(PopupMenuItem<String>, 'Delete worktree'),
    );
    expect(rename.enabled, isFalse);
    expect(delete.enabled, isFalse);
  });

  testWidgets('Hide the repo invokes removeProject', (tester) async {
    final store = await _pumpWithStore(
      tester,
      repos: [
        _repo(
          'p1',
          'alpha',
          worktrees: [_worktree('wt-main', branch: 'main', isPrimary: true)],
        ),
      ],
      sessions: const [],
    );

    await _openRepoMenu(tester, 'alpha');
    await tester.tap(find.text('Hide the repo'));
    await tester.pumpAndSettle();

    expect(store.hidden, ['p1']);
  });

  testWidgets('a failed Hide shows an error snackbar', (tester) async {
    await _pumpWithStore(
      tester,
      repos: [
        _repo(
          'p1',
          'alpha',
          worktrees: [_worktree('wt-main', branch: 'main', isPrimary: true)],
        ),
      ],
      sessions: const [],
      fail: true,
    );

    await _openRepoMenu(tester, 'alpha');
    await tester.tap(find.text('Hide the repo'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Hide failed'), findsOneWidget);
  });

  testWidgets('Delete worktree confirms then invokes removeWorktree', (
    tester,
  ) async {
    final store = await _pumpWithStore(
      tester,
      repos: [
        _repo(
          'p1',
          'alpha',
          worktrees: [
            _worktree('wt-feat', branch: 'feat/login', sessionIds: ['s1']),
          ],
        ),
      ],
      sessions: [_session('s1', 'p1', 'work', 'pi')],
    );

    await _openWorktreeMenu(tester, 'feat/login');
    await tester.tap(find.text('Delete worktree'));
    await tester.pumpAndSettle();

    // The confirmation dialog appears; cancelling issues no command.
    expect(find.text('Cancel'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(store.removedWorktrees, isEmpty);

    // Reopen and confirm this time.
    await _openWorktreeMenu(tester, 'feat/login');
    await tester.tap(find.text('Delete worktree'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(store.removedWorktrees, ['/tmp/wt/wt-feat']);
  });

  testWidgets('Rename branch submits the new name via renameBranch', (
    tester,
  ) async {
    final store = await _pumpWithStore(
      tester,
      repos: [
        _repo(
          'p1',
          'alpha',
          worktrees: [
            _worktree('wt-feat', branch: 'feat/login', sessionIds: ['s1']),
          ],
        ),
      ],
      sessions: [_session('s1', 'p1', 'work', 'pi')],
    );

    await _openWorktreeMenu(tester, 'feat/login');
    await tester.tap(find.text('Rename branch'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'feat/renamed');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();

    expect(store.renames, [(path: '/tmp/wt/wt-feat', name: 'feat/renamed')]);
  });

  testWidgets('fold button collapses the sidebar via the provider', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => null,
        );
    final container = await _pump(tester, repos: const [], sessions: const []);

    expect(container.read(sidebarCollapsedProvider), isFalse);
    await tester.tap(find.byTooltip('Hide sidebar'));
    await tester.pump();
    expect(container.read(sidebarCollapsedProvider), isTrue);
  });

  testWidgets('untitled session falls back to its agent name', (tester) async {
    await _pump(
      tester,
      repos: [
        _repo(
          'p1',
          'alpha',
          worktrees: [
            _worktree('wt-main', branch: 'main', sessionIds: ['s1']),
          ],
        ),
      ],
      sessions: [_session('s1', 'p1', '', 'codex')],
    );

    expect(find.text('codex'), findsOneWidget);
    expect(find.text('s1'), findsNothing);
  });

  testWidgets('session tiles are single-line: no avatar, preview, or chip', (
    tester,
  ) async {
    await _pump(
      tester,
      repos: [
        _repo(
          'p1',
          'alpha',
          worktrees: [
            _worktree('wt-main', branch: 'main', sessionIds: ['s1']),
          ],
        ),
      ],
      sessions: [
        _session(
          's1',
          'p1',
          'Fix login bug',
          'codex',
          status: SessionStatus.running,
          lastPreview: 'Patched pairing_screen.dart, ran tests.',
        ),
      ],
    );

    expect(find.byType(AgentAvatar), findsNothing);
    expect(find.text('Patched pairing_screen.dart, ran tests.'), findsNothing);
    expect(find.text('running'), findsNothing); // text chip replaced by a dot
    expect(find.byType(SessionStatusChip), findsNothing);
    // The status is surfaced as a dot with an accessible tooltip/semantics.
    expect(find.byTooltip('running'), findsOneWidget);
  });

  testWidgets('exited sessions are hidden from the repo groups', (
    tester,
  ) async {
    await _pump(
      tester,
      repos: [
        _repo(
          'p1',
          'alpha',
          worktrees: [
            _worktree('wt-main', branch: 'main', sessionIds: ['live', 'dead']),
          ],
        ),
      ],
      sessions: [
        _session(
          'live',
          'p1',
          'Live one',
          'codex',
          status: SessionStatus.running,
        ),
        _session(
          'dead',
          'p1',
          'Exited one',
          'codex',
          status: SessionStatus.exited,
        ),
      ],
    );
    // The live session shows; the exited one is filtered out (it lives in the
    // Archive surface instead).
    expect(find.text('Live one'), findsOneWidget);
    expect(find.text('Exited one'), findsNothing);
  });

  testWidgets('cold resumable (exited) sessions stay visible in repo groups', (
    tester,
  ) async {
    await _pump(
      tester,
      repos: [
        _repo(
          'p1',
          'alpha',
          worktrees: [
            _worktree('wt-main', branch: 'main', sessionIds: ['dead', 'cold']),
          ],
        ),
      ],
      sessions: [
        _session(
          'dead',
          'p1',
          'Dead one',
          'codex',
          status: SessionStatus.exited,
        ),
        // Resumable cold session (e.g. right after a server restart) must remain
        // discoverable so it can be reopened — it auto-attaches on subscribe.
        _session(
          'cold',
          'p1',
          'Resumable cold',
          'codex',
          status: SessionStatus.exited,
          resumable: true,
        ),
      ],
    );
    expect(find.text('Dead one'), findsNothing);
    expect(find.text('Resumable cold'), findsOneWidget);
  });

  testWidgets('idle sessions render no status dot', (tester) async {
    await _pump(
      tester,
      repos: [
        _repo(
          'p1',
          'alpha',
          worktrees: [
            _worktree('wt-main', branch: 'main', sessionIds: ['s1']),
          ],
        ),
      ],
      sessions: [_session('s1', 'p1', 'Fix login bug', 'codex')],
    );

    expect(find.byTooltip('idle'), findsNothing);
    expect(find.byTooltip('running'), findsNothing);
  });

  testWidgets('status dot follows in-place status transitions', (tester) async {
    SessionsState state(SessionStatus status) => SessionsState([
      _session('s1', 'p1', 'Fix login bug', 'codex', status: status),
    ]);
    final mutable = StateProvider<SessionsState>(
      (_) => state(SessionStatus.running),
    );
    final container = ProviderContainer(
      overrides: [
        reposProvider.overrideWithValue(
          ReposState([
            _repo(
              'p1',
              'alpha',
              worktrees: [
                _worktree('wt-main', branch: 'main', sessionIds: ['s1']),
              ],
            ),
          ]),
        ),
        sessionsProvider.overrideWith((ref) => ref.watch(mutable)),
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
    expect(find.byTooltip('running'), findsOneWidget);

    // running → error: the pulsing controller must stop (pumpAndSettle would
    // hang otherwise) and the dot must re-label. (exited is used elsewhere but
    // exited sessions are now hidden from the sidebar, so use a visible
    // non-pulsing status here.)
    container.read(mutable.notifier).state = state(SessionStatus.error);
    await tester.pumpAndSettle();
    expect(find.byTooltip('running'), findsNothing);
    expect(find.byTooltip('error'), findsOneWidget);

    // error → running: pulsing resumes on the reused State object.
    container.read(mutable.notifier).state = state(SessionStatus.running);
    await tester.pump();
    expect(find.byTooltip('running'), findsOneWidget);
  });

  for (final entry in {
    SessionStatus.awaitingInput: 'awaiting input',
    SessionStatus.awaitingApproval: 'awaiting approval',
    SessionStatus.error: 'error',
  }.entries) {
    testWidgets('status dot tooltip for ${entry.key} reads "${entry.value}"', (
      tester,
    ) async {
      await _pump(
        tester,
        repos: [
          _repo(
            'p1',
            'alpha',
            worktrees: [
              _worktree('wt-main', branch: 'main', sessionIds: ['s1']),
            ],
          ),
        ],
        sessions: [
          _session('s1', 'p1', 'Fix login bug', 'codex', status: entry.key),
        ],
      );

      expect(find.byTooltip(entry.value), findsOneWidget);
    });
  }

  testWidgets('PR pill renders on its own line below the branch row', (
    tester,
  ) async {
    await _pump(
      tester,
      repos: [
        _repo(
          'p1',
          'alpha',
          worktrees: [
            _worktree(
              'wt-feat',
              branch: 'feat/x',
              insertions: 1,
              deletions: 1,
              sessionIds: ['s1'],
              pr: const PullRequest(
                number: 42,
                url: '',
                state: 'OPEN',
                title: 'x',
                isDraft: false,
              ),
            ),
          ],
        ),
      ],
      sessions: [_session('s1', 'p1', 'work', 'pi')],
    );

    // The diff chip stays inline with the branch row...
    expect(find.text('+1'), findsOneWidget);
    // ...while the PR label drops to its own line below it.
    final branchY = tester.getTopLeft(find.text('feat/x')).dy;
    final prY = tester.getTopLeft(find.text('PR #42')).dy;
    expect(prY, greaterThan(branchY));
  });

  testWidgets(
    'worktree collapse state follows worktree identity, not list position',
    (tester) async {
      // Regression: _WorktreeGroup is keyed by worktree id so collapsing one
      // worktree's sessions survives the list being reordered underneath it.
      // reposProvider is a plain (non-state) Provider, so route it through a
      // StateProvider proxy to allow pushing a new value mid-test.
      final reposOverride = StateProvider<ReposState>(
        (_) => ReposState([
          _repo(
            'p1',
            'alpha',
            worktrees: [
              _worktree('wt-a', branch: 'branch-a', sessionIds: ['s1']),
              _worktree('wt-b', branch: 'branch-b', sessionIds: ['s2']),
            ],
          ),
        ]),
      );
      final container = ProviderContainer(
        overrides: [
          reposProvider.overrideWith((ref) => ref.watch(reposOverride)),
          sessionsProvider.overrideWithValue(
            SessionsState([
              _session('s1', 'p1', 'Session A', 'codex'),
              _session('s2', 'p1', 'Session B', 'codex'),
            ]),
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

      // Collapse the first worktree (branch-a) via its caret — the row itself
      // navigates now (SPEC-30 decision 15).
      await tester.tap(find.byKey(const Key('worktreeCaret-/tmp/wt/wt-a')));
      await tester.pumpAndSettle();
      expect(find.text('Session A'), findsNothing);
      expect(find.text('Session B'), findsOneWidget);

      // Reorder the worktrees underneath the same widget tree — branch-a is
      // now second. Its collapsed state must travel with it via the key.
      container.read(reposOverride.notifier).state = ReposState([
        _repo(
          'p1',
          'alpha',
          worktrees: [
            _worktree('wt-b', branch: 'branch-b', sessionIds: ['s2']),
            _worktree('wt-a', branch: 'branch-a', sessionIds: ['s1']),
          ],
        ),
      ]);
      await tester.pumpAndSettle();

      expect(find.text('Session A'), findsNothing);
      expect(find.text('Session B'), findsOneWidget);
    },
  );

  testWidgets('footer action icons sit flush against the sidebar right edge', (
    tester,
  ) async {
    const width = 320.0;
    const rightPadding = 8.0;
    final container = ProviderContainer(
      overrides: [
        reposProvider.overrideWithValue(ReposState(const [])),
        sessionsProvider.overrideWithValue(SessionsState(const [])),
        // A paired+connected server: the endpoint label shows and the
        // connection chip collapses — the layout the user actually sees.
        connectionProvider.overrideWithValue(
          MakitConnState(
            wsState: WsState.connected,
            servers: [
              PairedServer(
                host: '127.0.0.1',
                port: 9787,
                fingerprint: 'f',
                bearer: 'b',
                label: 'srv',
              ),
            ],
            activeId: 'f',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: width,
              child: DesktopSidebar(onOpenSettings: () {}),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('localhost:9787'), findsOneWidget);
    final settings = tester.getRect(
      find.ancestor(
        of: find.byTooltip('Settings & Server'),
        matching: find.byType(IconButton),
      ),
    );
    expect(
      settings.right,
      moreOrLessEquals(width - rightPadding, epsilon: 1),
      reason:
          'the last footer icon must end at the footer padding, not float '
          'in the middle of the row',
    );
  });

  group('SPEC-30 Lane 6 — sidebar board affordances (decisions 14, 15)', () {
    Future<ProviderContainer> pumpWithGroups(
      WidgetTester tester, {
      required List<RepoInfo> repos,
      required List<Session> sessions,
      required Group group,
    }) async {
      final container = ProviderContainer(
        overrides: [
          reposProvider.overrideWithValue(ReposState(repos)),
          sessionsProvider.overrideWithValue(SessionsState(sessions)),
          groupsControllerProvider.overrideWith(
            (ref) => GroupsController.ephemeral(
              GroupsState(groups: [group], activeGroupId: group.id),
            ),
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
      await tester.pump();
      return container;
    }

    Group board(List<String> members) => Group.board(
      id: 'b1',
      label: 'Shipping',
      members: members,
      tree: WorkspaceController.seedWorkspace(),
    );

    Group worktreeGroup() => Group.worktree(
      id: 'g1',
      projectId: 'p1',
      worktreePath: '/tmp/wt/wt-feat',
      label: 'feat/login',
      tree: WorkspaceController.seedWorkspace(),
    );

    final repos = [
      _repo(
        'p1',
        'alpha',
        worktrees: [
          _worktree('wt-feat', branch: 'feat/login', sessionIds: ['s1']),
        ],
      ),
    ];
    final sessions = [_session('s1', 'p1', 'Fix login bug', 'codex')];

    testWidgets('a hover quick-pin appears only when a board is active', (
      tester,
    ) async {
      // Worktree group active → no quick-pin (its membership is derived).
      await pumpWithGroups(
        tester,
        repos: repos,
        sessions: sessions,
        group: worktreeGroup(),
      );
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.text('Fix login bug')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sidebarQuickPin')), findsNothing);
    });

    testWidgets('the quick-pin pins the session to the active board', (
      tester,
    ) async {
      final container = await pumpWithGroups(
        tester,
        repos: repos,
        sessions: sessions,
        group: board(const []),
      );

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.text('Fix login bug')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('sidebarQuickPin')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sidebarQuickPin')));
      await tester.pump();

      // Pinned exactly once (decision 3).
      expect(container.read(groupsControllerProvider).active.members, ['s1']);
    });

    testWidgets('a board member shows the violet pin dot, not the quick-pin', (
      tester,
    ) async {
      await pumpWithGroups(
        tester,
        repos: repos,
        sessions: sessions,
        group: board(['s1']),
      );

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.text('Fix login bug')));
      await tester.pumpAndSettle();

      expect(find.byIcon(PhosphorIconsFill.circle), findsOneWidget);
      expect(find.byKey(const Key('sidebarQuickPin')), findsNothing);
    });

    testWidgets('tapping a worktree row activates (mints) its group', (
      tester,
    ) async {
      final container = await pumpWithGroups(
        tester,
        repos: repos,
        sessions: sessions,
        group: board(const []),
      );
      expect(
        container.read(groupsControllerProvider).active.kind,
        GroupKind.board,
      );

      await tester.tap(find.text('feat/login'));
      await tester.pump();

      final active = container.read(groupsControllerProvider).active;
      expect(active.kind, GroupKind.worktree);
      expect(active.worktreePath, '/tmp/wt/wt-feat');
    });

    testWidgets('the caret discloses without moving the canvas', (
      tester,
    ) async {
      final container = await pumpWithGroups(
        tester,
        repos: repos,
        sessions: sessions,
        group: board(const []),
      );
      final before = container.read(groupsControllerProvider).active.id;

      // The session is visible while expanded...
      expect(find.text('Fix login bug'), findsOneWidget);

      await tester.tap(find.byKey(const Key('worktreeCaret-/tmp/wt/wt-feat')));
      await tester.pumpAndSettle();

      // ...and the caret actually collapsed it. Asserting only that the active
      // group is unchanged would pass if the caret key were misspelled or the
      // control inert, which is the failure this test exists to catch.
      expect(find.text('Fix login bug'), findsNothing);
      expect(
        container.read(groupsControllerProvider).active.id,
        before,
        reason: 'expanding a row is not a navigation',
      );
    });
  });
}
