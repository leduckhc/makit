// SPEC-open-ports §1 — the ports glyph on the mobile worktree row. It sits in the
// trailing control column between the fold caret and `+` (order
// `branch · fold · ports · +`), renders nothing when the branch serves nothing,
// and opens the ports list sheet on tap (never folds the row).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/ports.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/ui/home/worktree_row.dart';
import 'package:makit/ui/ports/ports_glyph.dart';

class _EmptyStorage implements SecureStore {
  const _EmptyStorage();
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String? value}) async {}
  @override
  Future<void> delete({required String key}) async {}
}

const _repo = RepoInfo(
  id: 'p1',
  name: 'demo',
  path: '/tmp/demo',
  pinned: false,
  lastActivityAt: 0,
  isGitRepo: true,
  defaultBranch: 'main',
  currentBranch: 'main',
  worktrees: [],
);

const _worktree = Worktree(
  id: '/tmp/feature',
  path: '/tmp/feature',
  branch: 'add-login',
  isPrimary: false,
  insertions: 0,
  deletions: 0,
  filesChanged: 0,
  sessionIds: [],
);

PortsSnapshot _snap(String worktreePath) => PortsSnapshot(
  ports: [
    PortInfo(
      key: '100:127.0.0.1:5173',
      port: 5173,
      address: '127.0.0.1',
      reach: PortReach.loopback,
      pid: 100,
      command: 'node vite --port 5173',
      startedAt: 0,
      worktreePath: worktreePath,
      health: const PortHealth(
        kind: PortHealthKind.ok,
        status: 200,
        probedAt: 0,
      ),
      openUrl: 'http://127.0.0.1:5173',
    ),
  ],
  scannedAt: 0,
  scanOk: true,
);

Future<void> _pump(
  WidgetTester tester,
  PortsSnapshot? ports, {
  List<Session> sessions = const [],
}) async {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: WorktreeRow(
            repo: _repo,
            worktree: _worktree,
            sessions: sessions,
          ),
        ),
      ),
    ],
  );
  final container = ProviderContainer(
    overrides: [
      connectionControllerProvider.overrideWith(
        (ref) => ConnectionController(const _EmptyStorage()),
      ),
      if (ports != null) portsProvider.overrideWithValue(ports),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('no glyph when the worktree serves nothing', (tester) async {
    await _pump(tester, null);
    expect(find.byType(PortsGlyph), findsNothing);
  });

  testWidgets('glyph appears when this worktree owns a port', (tester) async {
    await _pump(tester, _snap('/tmp/feature'));
    expect(find.byType(PortsGlyph), findsOneWidget);
  });

  testWidgets('tapping the glyph opens the ports list sheet, does not fold', (
    tester,
  ) async {
    // The row must be foldable for "does not fold" to mean anything: an empty
    // session list makes `canFold` false, so a tap could not fold under ANY
    // implementation. Give it one session (the row starts expanded), then prove
    // the glyph swallowed the tap — the session tile is still visible after.
    final session = Session(
      id: 's1',
      projectId: 'p1',
      agent: 'pi',
      title: 'wire the ports snapshot',
      status: SessionStatus.exited,
      policy: ApprovalPolicy.askOnRisky,
    );
    await _pump(tester, _snap('/tmp/feature'), sessions: [session]);
    // The session tile is visible while the row is expanded.
    expect(find.text('wire the ports snapshot'), findsOneWidget);

    await tester.tap(find.byType(PortsGlyph));
    await tester.pumpAndSettle();
    // Sheet 1's header names the branch.
    expect(find.text('Ports · add-login'), findsOneWidget);
    // The single port's tappable row is present.
    expect(find.byKey(const ValueKey('ports-list-row-5173')), findsOneWidget);
    // The tap opened the sheet WITHOUT folding the row: the session tile behind
    // the sheet is still there (a fold would have collapsed it).
    expect(find.text('wire the ports snapshot'), findsOneWidget);
  });
}
