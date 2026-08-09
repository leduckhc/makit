// SPEC-43 P3a D8 — the confirm is the mitigation, so it gets its own tests.
//
// The properties that matter: the dialog NAMES the victim (not "Are you sure?"),
// dismissing it sends nothing at all, confirming sends exactly the tuple that was
// displayed, and every outcome — including a refusal — is reported back.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/ports.dart';
import 'package:makit/ui/ports/port_kill_confirm.dart';

PortInfo _port({int? startedAt = 1_700_000}) => PortInfo(
  key: '48211:127.0.0.1:5173',
  port: 5173,
  address: '127.0.0.1',
  reach: PortReach.loopback,
  pid: 48211,
  command: '/opt/node_modules/.bin/vite --port 5173',
  startedAt: startedAt,
  worktreePath: '/wt/feat',
);

/// A killer that records every command body and answers with [outcome].
class _RecordingKiller extends PortsKiller {
  _RecordingKiller(this.outcome, this.bodies)
    : super((body) async {
        bodies.add(body);
        return {'outcome': outcome};
      });

  final String outcome;
  final List<Map<String, dynamic>> bodies;
}

Future<PortKillOutcome?> _tapKill(
  WidgetTester tester, {
  required PortsKiller killer,
  PortInfo? port,
}) async {
  PortKillOutcome? result;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [portsKillerProvider.overrideWithValue(killer)],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () async {
                result = await confirmAndKillPort(
                  context,
                  ref,
                  port ?? _port(),
                  branchLabel: 'feat/open-ports',
                );
              },
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('the dialog names the process, pid, port and branch', (
    tester,
  ) async {
    final bodies = <Map<String, dynamic>>[];
    await _tapKill(tester, killer: _RecordingKiller('released', bodies));

    expect(find.text('Kill :5173?'), findsOneWidget);
    expect(find.textContaining('vite'), findsOneWidget);
    expect(find.textContaining('pid 48211'), findsOneWidget);
    expect(find.textContaining(':5173'), findsWidgets);
    expect(find.textContaining('feat/open-ports'), findsOneWidget);
    // It says what will happen, in the order it happens.
    expect(find.textContaining('SIGTERM'), findsOneWidget);
    expect(find.textContaining('SIGKILL'), findsOneWidget);
    expect(bodies, isEmpty, reason: 'nothing is sent before the user confirms');
  });

  testWidgets('Cancel sends NOTHING', (tester) async {
    final bodies = <Map<String, dynamic>>[];
    await _tapKill(tester, killer: _RecordingKiller('released', bodies));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(bodies, isEmpty);
  });

  testWidgets('confirming sends exactly the displayed tuple (D1)', (
    tester,
  ) async {
    final bodies = <Map<String, dynamic>>[];
    await _tapKill(tester, killer: _RecordingKiller('released', bodies));
    await tester.tap(find.widgetWithText(FilledButton, 'Kill'));
    await tester.pumpAndSettle();

    expect(bodies, [
      {
        'kind': 'ports.kill',
        'address': '127.0.0.1',
        'port': 5173,
        'pid': 48211,
        'startedAt': 1700000,
      },
    ]);
    expect(find.text(':5173 released.'), findsOneWidget);
  });

  testWidgets('a refusal is reported with its own sentence, not silence', (
    tester,
  ) async {
    final bodies = <Map<String, dynamic>>[];
    await _tapKill(
      tester,
      killer: _RecordingKiller('identity_mismatch', bodies),
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Kill'));
    await tester.pumpAndSettle();
    expect(find.textContaining('changed since you looked'), findsOneWidget);
  });

  testWidgets('an unknown outcome reports a failure, never a success', (
    tester,
  ) async {
    final bodies = <Map<String, dynamic>>[];
    await _tapKill(tester, killer: _RecordingKiller('teleported', bodies));
    await tester.tap(find.widgetWithText(FilledButton, 'Kill'));
    await tester.pumpAndSettle();
    expect(find.text('The kill did not go through.'), findsOneWidget);
  });

  testWidgets('an unverifiable port never even opens the dialog (D1)', (
    tester,
  ) async {
    final bodies = <Map<String, dynamic>>[];
    final outcome = await _tapKill(
      tester,
      killer: _RecordingKiller('released', bodies),
      port: _port(startedAt: null),
    );
    expect(find.text('Kill :5173?'), findsNothing);
    expect(outcome, isNull);
    expect(bodies, isEmpty);
  });
}
