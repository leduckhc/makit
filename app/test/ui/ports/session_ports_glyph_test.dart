// SPEC-42 P2a T6 — the session-tile ports glyph (D14). Quieter than the row
// glyph (no attention dot), renders only for a port owned by this session, and
// opens the per-worktree ports surface on tap.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/ports.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/ports/ports_glyph.dart';
import 'package:makit/ui/ports/session_ports_glyph.dart';
import 'package:makit/ui/ports/worktree_ports_sheet.dart';

PortInfo _port({
  required int port,
  String? sessionId = 's1',
  String? worktreePath = '/wt/feat',
  PortHealth? health,
}) => PortInfo(
  key: '$port:x:$port',
  port: port,
  address: '127.0.0.1',
  reach: PortReach.loopback,
  pid: port,
  command: 'node vite',
  worktreePath: worktreePath,
  sessionId: sessionId,
  health: health,
);

final _repos = ReposState([
  const RepoInfo(
    id: 'A',
    name: 'makit',
    path: '/A',
    pinned: false,
    lastActivityAt: 0,
    isGitRepo: true,
    defaultBranch: 'main',
    currentBranch: 'main',
    worktrees: [
      Worktree(
        id: '/wt/feat',
        path: '/wt/feat',
        branch: 'feat/open-ports',
        isPrimary: false,
        insertions: 0,
        deletions: 0,
        filesChanged: 0,
        sessionIds: [],
      ),
    ],
  ),
]);

Future<void> _pump(WidgetTester tester, List<PortInfo> ports) async {
  final container = ProviderContainer(
    overrides: [
      portsProvider.overrideWithValue(
        PortsSnapshot(ports: ports, scannedAt: 0, scanOk: true),
      ),
      reposProvider.overrideWithValue(_repos),
      sessionsProvider.overrideWithValue(SessionsState(const [])),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: SessionPortsGlyph(sessionId: 's1')),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders nothing when no port has this sessionId', (
    tester,
  ) async {
    await _pump(tester, [_port(port: 5173, sessionId: 'other')]);
    expect(find.byType(PortsGlyph), findsNothing);
  });

  testWidgets('renders quietly (no attention dot) when a port matches', (
    tester,
  ) async {
    // A refused port would light the row glyph's attention dot; the session
    // glyph stays quiet (D14 — the row already carries attention).
    await _pump(tester, [
      _port(
        port: 5173,
        health: const PortHealth(kind: PortHealthKind.refused, probedAt: 0),
      ),
    ]);
    expect(find.byType(PortsGlyph), findsOneWidget);
    expect(find.byKey(kPortsAttentionDot), findsNothing);
  });

  testWidgets('its semantics label names the session\'s port', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, [_port(port: 5173)]);
    expect(find.bySemanticsLabel(RegExp('listening')), findsWidgets);
    handle.dispose();
  });

  testWidgets('tapping opens the per-worktree ports surface', (tester) async {
    await _pump(tester, [_port(port: 5173)]);
    await tester.tap(find.byType(SessionPortsGlyph));
    await tester.pumpAndSettle();
    expect(find.byType(WorktreePortsSheetBody), findsOneWidget);
  });
}
