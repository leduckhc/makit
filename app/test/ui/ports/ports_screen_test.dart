// SPEC-42 P2a T3 — the global Ports screen widget.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/ports.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/ports/port_detail_sheet.dart';
import 'package:makit/ui/ports/ports_screen.dart';

PortInfo _port({
  required int port,
  String? worktreePath = '/A/feat',
  PortReach reach = PortReach.loopback,
}) => PortInfo(
  key: '$port:x:$port',
  port: port,
  address: reach == PortReach.exposed ? '0.0.0.0' : '127.0.0.1',
  reach: reach,
  pid: port,
  command: 'node vite --port $port',
  worktreePath: worktreePath,
  openUrl: 'http://127.0.0.1:$port',
);

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

final _repos = ReposState([
  RepoInfo(
    id: 'A',
    name: 'makit',
    path: '/A',
    pinned: false,
    lastActivityAt: 0,
    isGitRepo: true,
    defaultBranch: 'main',
    currentBranch: 'main',
    worktrees: [_wt('/A/feat', 'feat/open-ports')],
  ),
]);

Future<PortsWatch> _pump(
  WidgetTester tester,
  PortsSnapshot? snapshot, {
  String? repoId,
}) async {
  final watch = PortsWatch((_) {});
  final container = ProviderContainer(
    overrides: [
      portsWatchProvider.overrideWithValue(watch),
      portsProvider.overrideWithValue(snapshot),
      reposProvider.overrideWithValue(_repos),
      sessionsProvider.overrideWithValue(SessionsState(const [])),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: PortsScreen(repoId: repoId)),
    ),
  );
  await tester.pumpAndSettle();
  return watch;
}

PortsSnapshot _snap(List<PortInfo> ports, {bool scanOk = true}) =>
    PortsSnapshot(ports: ports, scannedAt: 0, scanOk: scanOk);

void main() {
  testWidgets('empty state when the scan succeeded with zero ports', (
    tester,
  ) async {
    await _pump(tester, _snap(const []));
    expect(find.byKey(kPortsEmptyState), findsOneWidget);
    expect(find.textContaining('No dev servers running'), findsOneWidget);
    expect(find.byKey(kPortsDegradedBanner), findsNothing);
  });

  testWidgets('degraded banner when scanOk is false (not a fake empty list)', (
    tester,
  ) async {
    await _pump(tester, _snap(const [], scanOk: false));
    expect(find.byKey(kPortsDegradedBanner), findsOneWidget);
    expect(find.byKey(kPortsEmptyState), findsNothing);
  });

  testWidgets('filter chips switch the visible set', (tester) async {
    await _pump(
      tester,
      _snap([_port(port: 5173), _port(port: 9787, reach: PortReach.exposed)]),
    );
    // All: both ports render.
    expect(find.text('5173'), findsOneWidget);
    expect(find.text('9787'), findsOneWidget);

    // Switch to Exposed: only the wildcard-bound port survives.
    await tester.tap(find.text('Exposed'));
    await tester.pumpAndSettle();
    expect(find.text('5173'), findsNothing);
    expect(find.text('9787'), findsOneWidget);
  });

  testWidgets('unowned-only renders the system group', (tester) async {
    await _pump(tester, _snap([_port(port: 22, worktreePath: null)]));
    expect(find.text('OTHER / SYSTEM'), findsOneWidget);
  });

  testWidgets('the system group is folded by default and unfolds on tap', (
    tester,
  ) async {
    // Mockup §6: "System listeners are collapsed by default — they're noise, not
    // work." The header is still shown (so the ports are discoverable), but its
    // rows must not push a real worktree's ports off the first screen.
    await _pump(tester, _snap([_port(port: 22, worktreePath: null)]));
    expect(find.text('OTHER / SYSTEM'), findsOneWidget);
    expect(find.text('22'), findsNothing);

    await tester.tap(find.text('OTHER / SYSTEM'));
    await tester.pumpAndSettle();
    expect(find.text('22'), findsOneWidget);
  });

  testWidgets('tapping a port opens the P1 detail sheet', (tester) async {
    await _pump(tester, _snap([_port(port: 5173)]));
    await tester.tap(find.text('5173'));
    await tester.pumpAndSettle();
    expect(find.byType(PortDetailSheetBody), findsOneWidget);
  });

  testWidgets('holds the ports watch while mounted, releases to 0 on dispose', (
    tester,
  ) async {
    final watch = await _pump(tester, _snap([_port(port: 5173)]));
    expect(watch.watcherCount, 1);
    await tester.pumpWidget(const SizedBox());
    expect(watch.watcherCount, 0);
  });
}
