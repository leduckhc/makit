import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/ports.dart';
import 'package:makit/ui/ports/port_detail_sheet.dart';
import 'package:makit/ui/ports/worktree_ports_sheet.dart';

PortInfo _port({
  int port = 5173,
  String? openUrl = 'http://127.0.0.1:5173',
  String? sessionId = 's1',
  PortHealth? health,
}) => PortInfo(
  key: '100:127.0.0.1:$port',
  port: port,
  address: '127.0.0.1',
  reach: PortReach.loopback,
  pid: 48211,
  command: 'node vite --port $port',
  startedAt: 1000,
  worktreePath: '/wt',
  sessionId: sessionId,
  health:
      health ??
      const PortHealth(kind: PortHealthKind.ok, status: 200, probedAt: 2000),
  openUrl: openUrl,
);

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('sheet 1 — the list', () {
    testWidgets('has no action buttons (nothing reachable from a flick)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          WorktreePortsSheetBody(
            branch: 'feat/open-ports',
            ports: [_port(port: 5173), _port(port: 9787)],
            onOpenPort: (_) {},
          ),
        ),
      );
      expect(find.text('Open'), findsNothing);
      expect(find.text('Copy URL'), findsNothing);
      expect(find.text('Kill'), findsNothing);
      // Two tappable port rows, each with a chevron.
      expect(find.byIcon(Icons.chevron_right), findsNothing); // uses phosphor
      expect(find.byKey(const ValueKey('ports-list-row-5173')), findsOneWidget);
      expect(find.byKey(const ValueKey('ports-list-row-9787')), findsOneWidget);
    });

    testWidgets('tapping a row invokes onOpenPort with that port', (
      tester,
    ) async {
      PortInfo? opened;
      await tester.pumpWidget(
        _host(
          WorktreePortsSheetBody(
            branch: 'feat/open-ports',
            ports: [_port(port: 5173)],
            onOpenPort: (p) => opened = p,
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('ports-list-row-5173')));
      expect(opened?.port, 5173);
    });
  });

  group('sheet 2 — the detail', () {
    testWidgets('lists every fact', (tester) async {
      await tester.pumpWidget(
        _host(
          PortDetailSheetBody(
            port: _port(),
            branchLabel: 'feat/open-ports',
            sessionLabel: 'wire the ports snapshot',
            nowMs: 100000 + 41 * 60 * 1000 + 1000,
          ),
        ),
      );
      expect(find.text('worktree'), findsOneWidget);
      expect(find.text('session'), findsOneWidget);
      expect(find.text('command'), findsOneWidget);
      expect(find.text('pid'), findsOneWidget);
      expect(find.text('uptime'), findsOneWidget);
      expect(find.text('bound'), findsOneWidget);
      expect(find.text('probe'), findsOneWidget);
      // The two P1 actions, present when openUrl is set.
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Copy URL'), findsOneWidget);
      // No destructive control in P1.
      expect(find.text('Kill'), findsNothing);
      expect(find.textContaining('Kill'), findsNothing);
    });

    testWidgets('hides Open and Copy URL when openUrl is absent', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          PortDetailSheetBody(
            port: _port(openUrl: null),
            branchLabel: 'feat/open-ports',
            sessionLabel: null,
            nowMs: 100000,
          ),
        ),
      );
      expect(find.text('Open'), findsNothing);
      expect(find.text('Copy URL'), findsNothing);
    });

    testWidgets('Copy URL writes the url to the clipboard', (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await tester.pumpWidget(
        _host(
          PortDetailSheetBody(
            port: _port(),
            branchLabel: 'feat/open-ports',
            sessionLabel: null,
            nowMs: 100000,
          ),
        ),
      );
      await tester.tap(find.text('Copy URL'));
      await tester.pump();
      expect(calls, hasLength(1));
      expect((calls.single.arguments as Map)['text'], 'http://127.0.0.1:5173');
    });
  });
}
