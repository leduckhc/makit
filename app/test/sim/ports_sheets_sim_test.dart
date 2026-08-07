// Audit harness for the two SPEC-41 mobile port surfaces — sheet 1 (the
// worktree's list) and sheet 2 (one port's detail) — rendered against
// `mockups/open-ports.html` §2b at iPhone 393pt.
//
//   PORTS_AUDIT=1 flutter test --no-pub --update-goldens test/sim/ports_sheets_sim_test.dart
//
// These exist because the tinted-token pass touched all four port surfaces, and
// two of them had no image: a unit test proves the tone is right, only a render
// proves the two-line row still fits its 56 pt tap target.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/store/ports.dart';
import 'package:makit/ui/ports/port_detail_sheet.dart';
import 'package:makit/ui/ports/worktree_ports_sheet.dart';

import 'sim_fonts.dart';

final int _nowMs = DateTime.now().millisecondsSinceEpoch;

PortInfo _port({
  required int port,
  required String command,
  String address = '127.0.0.1',
  PortReach reach = PortReach.loopback,
  int pid = 48211,
  PortHealth? health,
  String? openUrl,
  int? startedAt,
}) => PortInfo(
  key: '$pid:$address:$port',
  port: port,
  address: address,
  reach: reach,
  pid: pid,
  command: command,
  startedAt: startedAt ?? _nowMs - 41 * 60 * 1000,
  health: health,
  openUrl: openUrl,
);

/// One port per tone, so a single image shows whether the four verdicts are
/// distinguishable on a phone.
final _ports = [
  _port(
    port: 5173,
    command: '/opt/homebrew/Cellar/node/26.5.1/bin/node vite --port 5173',
    health: PortHealth(
      kind: PortHealthKind.ok,
      status: 200,
      probedAt: _nowMs - 4000,
    ),
    openUrl: 'http://127.0.0.1:5173',
  ),
  _port(
    port: 9787,
    command: '/opt/homebrew/Cellar/node/26.5.1/bin/node dist/serve.js',
    address: '0.0.0.0',
    reach: PortReach.exposed,
    pid: 47120,
    health: PortHealth(
      kind: PortHealthKind.httpError,
      status: 404,
      probedAt: _nowMs - 3000,
    ),
    openUrl: 'http://127.0.0.1:9787',
    startedAt: _nowMs - 2 * 60 * 60 * 1000,
  ),
  _port(
    port: 5175,
    command: '/opt/homebrew/Cellar/node/26.5.1/bin/node vite --port 5175',
    pid: 50110,
    health: PortHealth(kind: PortHealthKind.refused, probedAt: _nowMs - 2000),
    startedAt: _nowMs - 12 * 60 * 1000,
  ),
  _port(
    port: 5432,
    command: '/usr/local/opt/postgresql@16/bin/postgres -D /data',
    pid: 51002,
    startedAt: _nowMs - 3 * 24 * 60 * 60 * 1000,
  ),
];

Widget _scene(Widget body) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: makitDarkTheme,
  home: Scaffold(
    backgroundColor: makitDarkTheme.colorScheme.surfaceContainerLow,
    body: SafeArea(child: body),
  ),
);

void main() {
  setUpAll(loadSimFonts);

  testWidgets('ports sheet 1 — the worktree list', (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 520 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _scene(
        WorktreePortsSheetBody(
          branch: 'feat/open-ports',
          ports: _ports,
          nowMs: _nowMs,
          onOpenPort: (_) {},
          onOpenPortsScreen: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('images/ports_sheet_list.png'),
    );
  }, skip: skipSimAudit);

  testWidgets('ports sheet 2 — one port in full', (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 620 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _scene(
        PortDetailSheetBody(
          port: _ports[1],
          branchLabel: 'feat/open-ports',
          sessionLabel: 'wire the ports popover',
          nowMs: _nowMs,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('images/ports_sheet_detail.png'),
    );
  }, skip: skipSimAudit);
}
