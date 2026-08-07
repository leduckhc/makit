// SPEC-42 P2a T5 — the `Ports (n)…` worktree overflow item (D8). It routes to
// the global Ports screen pre-filtered to the repo; it does NOT lift the
// popover's private controller.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:makit/app/routes.dart';
import 'package:makit/desktop/chat/desktop_sidebar.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/ports.dart';
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

RepoInfo _repo(String id, String name, List<Worktree> worktrees) => RepoInfo(
  id: id,
  name: name,
  path: '/$id',
  pinned: false,
  lastActivityAt: 0,
  isGitRepo: true,
  defaultBranch: 'main',
  currentBranch: 'main',
  worktrees: worktrees,
);

PortInfo _port(int port, String worktreePath) => PortInfo(
  key: '$port:x:$port',
  port: port,
  address: '127.0.0.1',
  reach: PortReach.loopback,
  pid: port,
  command: 'node vite',
  worktreePath: worktreePath,
);

Future<String? Function()> _pump(
  WidgetTester tester, {
  required List<RepoInfo> repos,
  required PortsSnapshot ports,
}) async {
  String? navigatedTo;
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) =>
            const Scaffold(body: SizedBox(width: 320, child: DesktopSidebar())),
      ),
      GoRoute(
        path: kRoutePorts,
        builder: (_, s) {
          navigatedTo = s.uri.toString();
          return const Scaffold(body: Text('PORTS SCREEN'));
        },
      ),
    ],
  );
  final container = ProviderContainer(
    overrides: [
      reposProvider.overrideWithValue(ReposState(repos)),
      sessionsProvider.overrideWithValue(SessionsState(const [])),
      portsProvider.overrideWithValue(ports),
      portsWatchProvider.overrideWithValue(PortsWatch((_) {})),
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
  // The ports route builder captures the visited location lazily.
  return () => navigatedTo;
}

Future<void> _openMenu(WidgetTester tester, String branch) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  await gesture.moveTo(tester.getCenter(find.text(branch)));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Worktree actions'));
  await tester.pumpAndSettle();
  await gesture.removePointer();
}

void main() {
  testWidgets('shows "Ports (n)…" with the worktree\'s owned port count', (
    tester,
  ) async {
    final repos = [
      _repo('p1', 'makit', [_wt('/wt/feat', 'feat/open-ports')]),
    ];
    final ports = PortsSnapshot(
      ports: [_port(5173, '/wt/feat'), _port(9787, '/wt/feat')],
      scannedAt: 0,
      scanOk: true,
    );
    await _pump(tester, repos: repos, ports: ports);
    await _openMenu(tester, 'feat/open-ports');
    expect(
      find.widgetWithText(PopupMenuItem<String>, 'Ports (2)…'),
      findsOneWidget,
    );
  });

  testWidgets('the item is present even when the worktree owns no ports', (
    tester,
  ) async {
    final repos = [
      _repo('p1', 'makit', [_wt('/wt/feat', 'feat/open-ports')]),
    ];
    const ports = PortsSnapshot(ports: [], scannedAt: 0, scanOk: true);
    await _pump(tester, repos: repos, ports: ports);
    await _openMenu(tester, 'feat/open-ports');
    expect(
      find.widgetWithText(PopupMenuItem<String>, 'Ports (0)…'),
      findsOneWidget,
    );
  });

  testWidgets(
    'selecting it navigates to kRoutePorts pre-filtered to the repo',
    (tester) async {
      final repos = [
        _repo('p1', 'makit', [_wt('/wt/feat', 'feat/open-ports')]),
      ];
      final ports = PortsSnapshot(
        ports: [_port(5173, '/wt/feat')],
        scannedAt: 0,
        scanOk: true,
      );
      final read = await _pump(tester, repos: repos, ports: ports);
      await _openMenu(tester, 'feat/open-ports');
      await tester.tap(find.text('Ports (1)…'));
      await tester.pumpAndSettle();

      expect(find.text('PORTS SCREEN'), findsOneWidget);
      expect(read(), contains('repo=p1'));
    },
  );
}
