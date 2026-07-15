import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:makit/desktop/chat/desktop_sidebar.dart';
import 'package:makit/desktop/chat/selected_session.dart';
import 'package:makit/desktop/chat/sidebar_layout.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/home/repo_chips.dart';

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
}) => Session(
  id: id,
  projectId: projectId,
  agent: agent,
  title: title,
  status: status,
  policy: ApprovalPolicy.askOnRisky,
  pending: pending,
  lastPreview: lastPreview,
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

  testWidgets('worktree icon: merge symbol only when a PR is open', (
    tester,
  ) async {
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
          ],
        ),
      ],
      sessions: [
        _session('s1', 'p1', 'a', 'pi'),
        _session('s2', 'p1', 'b', 'pi'),
      ],
    );

    // Exactly one worktree has an open PR → one merge symbol; the PR-less
    // worktree keeps the plain fork/branch icon that predated the redesign.
    expect(find.byIcon(Symbols.call_merge), findsOneWidget);
    expect(find.byIcon(Symbols.fork_right), findsOneWidget);
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

    // running → exited: the pulsing controller must stop (pumpAndSettle would
    // hang otherwise) and the dot must re-label.
    container.read(mutable.notifier).state = state(SessionStatus.exited);
    await tester.pumpAndSettle();
    expect(find.byTooltip('running'), findsNothing);
    expect(find.byTooltip('exited'), findsOneWidget);

    // exited → running: pulsing resumes on the reused State object.
    container.read(mutable.notifier).state = state(SessionStatus.running);
    await tester.pump();
    expect(find.byTooltip('running'), findsOneWidget);
  });

  for (final entry in {
    SessionStatus.awaitingInput: 'awaiting input',
    SessionStatus.awaitingApproval: 'awaiting approval',
    SessionStatus.error: 'error',
    SessionStatus.exited: 'exited',
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
