// SPEC-42 P2a T5 — the `Ports (n)…` worktree overflow item (D8). It opens the
// global Ports screen pre-filtered to the repo; it does NOT lift the popover's
// private controller.
//
// The harness is a plain `MaterialApp(home: …)` ON PURPOSE: that is what the
// desktop shell is (only mobile uses `MaterialApp.router`). An earlier version
// of this test wrapped the sidebar in a GoRouter, which made a `context.go`
// implementation pass here while throwing *No GoRouter found in context* in the
// shipped app.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/desktop_sidebar.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/ports.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/ports/ports_screen.dart';

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

Future<void> _pump(
  WidgetTester tester, {
  required List<RepoInfo> repos,
  required PortsSnapshot ports,
}) async {
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
      child: const MaterialApp(
        home: Scaffold(body: SizedBox(width: 320, child: DesktopSidebar())),
      ),
    ),
  );
  await tester.pumpAndSettle();
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

  testWidgets('selecting it opens the Ports screen filtered to the repo', (
    tester,
  ) async {
    final repos = [
      _repo('p1', 'makit', [_wt('/wt/feat', 'feat/open-ports')]),
    ];
    final ports = PortsSnapshot(
      ports: [_port(5173, '/wt/feat')],
      scannedAt: 0,
      scanOk: true,
    );
    await _pump(tester, repos: repos, ports: ports);
    await _openMenu(tester, 'feat/open-ports');
    await tester.tap(find.text('Ports (1)…'));
    // Two pumps: the first dismisses the popup menu (which is what runs
    // `onSelected`), the second lets the pushed route's transition finish.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final screen = tester.widget<PortsScreen>(find.byType(PortsScreen));
    expect(screen.repoId, 'p1');
  });
}
