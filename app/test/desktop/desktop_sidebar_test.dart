import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/desktop/chat/desktop_sidebar.dart';
import 'package:makit/desktop/chat/selected_session.dart';
import 'package:makit/desktop/chat/sidebar_layout.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/home/repo_chips.dart';

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
    String? baseBranch,
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
  await gesture.moveTo(tester.getCenter(find.text(repoName.toUpperCase())));
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
  await gesture.moveTo(tester.getCenter(find.text(repoName.toUpperCase())));
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

    expect(find.text('ALPHA'), findsOneWidget);
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

  testWidgets('drafts render as a worktree row (no DRAFTS section)', (
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
      sessions: [_session('s1', 'p1', '', 'pi', pending: true)],
    );

    // The DRAFTS section header + `draft` tag were removed; a pending draft now
    // renders as a worktree-style row labelled "new worktree".
    expect(find.text('DRAFTS'), findsNothing);
    expect(find.text('new worktree'), findsOneWidget);
    expect(find.text('draft'), findsNothing);
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
    expect(
      find.byKey(const ValueKey('assets/icons/git-pull-request-closed.svg')),
      findsOneWidget,
    );
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

  testWidgets('tapping the worktree branch row collapses its sessions', (
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

    await tester.tap(find.text('feat/login'));
    await tester.pumpAndSettle();
    expect(find.text('Fix login bug'), findsNothing);

    await tester.tap(find.text('feat/login'));
    await tester.pumpAndSettle();
    expect(find.text('Fix login bug'), findsOneWidget);
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
    await tester.tap(find.text('ALPHA'));
    await tester.pumpAndSettle();
    expect(find.text('feat/login'), findsNothing);

    // Tapping again re-expands it.
    await tester.tap(find.text('ALPHA'));
    await tester.pumpAndSettle();
    expect(find.text('feat/login'), findsOneWidget);
  });

  testWidgets('repo header overflow menu lists Hide + New worktree', (
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

    // Repo actions surface only on hover, so move the pointer over the header.
    await _openRepoMenu(tester, 'alpha');
    expect(find.text('Hide the repo'), findsOneWidget);
    expect(find.text('New worktree from…'), findsOneWidget);
  });

  testWidgets('the + button spawns a pending draft without a dialog', (
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

    // A bare spawn (pending draft, no worktree on disk) is issued for the repo.
    expect(store.spawned, ['p1']);
    // No dialog opens: the richer picker only lives in the repo overflow menu.
    expect(find.text('New worktree from…'), findsNothing);
  });

  testWidgets(
    'a failed + spawn shows an error snackbar (no worktree materializes)',
    (tester) async {
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
        fail: true,
      );

      await _tapNewWorktree(tester, 'alpha');

      expect(store.spawned, ['p1']);
      expect(find.textContaining('New worktree failed'), findsOneWidget);
    },
  );

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

      // Collapse the first worktree (branch-a).
      await tester.tap(find.text('branch-a'));
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
}
